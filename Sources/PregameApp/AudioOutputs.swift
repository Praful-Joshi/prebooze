import CoreAudio
import Foundation
import os
import SwiftUI

/// The Mac's audio outputs and the one Pregame plays through: "System
/// Default" (follows macOS) or a device chosen by the user (remembered by
/// UID; if it disappears, the default is used until it comes back).
@MainActor
final class AudioOutputs: ObservableObject {
    static let shared = AudioOutputs()
    /// Posted when the device to play through changes (selection, plug/unplug, default change).
    nonisolated static let changed = Notification.Name("PregameOutputChanged")

    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var defaultID: AudioDeviceID = 0
    /// nil = System Default.
    @Published private(set) var selectedUID: String?

    private static let key = "outputDeviceUID"
    /// Read from the audio side (any thread).
    nonisolated static let current = OSAllocatedUnfairLock<AudioDeviceID>(initialState: 0)

    private init() {
        selectedUID = UserDefaults.standard.string(forKey: AudioOutputs.key)
        refresh()
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(system, &address, .main) { _, _ in
                MainActor.assumeIsolated { AudioOutputs.shared.refresh() }
            }
        }
    }

    /// The device sound goes to now.
    var effective: Device? {
        devices.first { $0.uid == selectedUID } ?? devices.first { $0.id == defaultID }
    }
    var selectedIsMissing: Bool { selectedUID != nil && !devices.contains { $0.uid == selectedUID } }

    func select(_ uid: String?) {
        selectedUID = uid
        UserDefaults.standard.set(uid, forKey: AudioOutputs.key)
        publish()
    }

    func refresh() {
        devices = AudioOutputs.outputDevices()
        defaultID = AudioOutputs.defaultOutput()
        publish()
    }

    private func publish() {
        let id = effective?.id ?? defaultID
        let changed = AudioOutputs.current.withLock { old -> Bool in
            defer { old = id }
            return old != id
        }
        if changed { NotificationCenter.default.post(name: AudioOutputs.changed, object: nil) }
    }

    // MARK: CoreAudio

    private static func defaultOutput() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    private static func outputDevices() -> [Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard outputChannels(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Device(id: id, uid: uid, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func outputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let s = value?.takeRetainedValue() else { return nil }
        return s as String
    }
}

/// Output picker, used by the Playback menu and Settings.
struct OutputDevicePicker: View {
    @ObservedObject var outputs = AudioOutputs.shared
    var label = "Output Device"

    var body: some View {
        Picker(label, selection: Binding(get: { outputs.selectedUID ?? "" },
                                         set: { outputs.select($0.isEmpty ? nil : $0) })) {
            Text("System Default" + (outputs.devices.first { $0.id == outputs.defaultID }.map { " (\($0.name))" } ?? ""))
                .tag("")
            Divider()
            ForEach(outputs.devices) { d in Text(d.name).tag(d.uid) }
            if outputs.selectedIsMissing, let uid = outputs.selectedUID {
                Text("Not connected (using default)").tag(uid)
            }
        }
    }
}
