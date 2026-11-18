import Foundation

/// A transition saved by the user as a preset (lanes, length, sync, tempo).
public struct UserPreset: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var spec: TransitionSpec

    public init(name: String, spec: TransitionSpec) {
        self.name = name
        self.spec = spec
    }

    /// The preset applied to a transition: its sound, but the transition's own
    /// placement (mix-on, nudges, delay) and never a lock.
    public func applied(to base: TransitionSpec) -> TransitionSpec {
        var s = spec
        s.preset = name
        s.mixOn = base.mixOn
        s.outNudge = base.outNudge
        s.inNudge = base.inNudge
        s.inDelay = base.inDelay
        s.locked = nil
        s.customised = true
        return s
    }
}

/// User presets, shared by every project:
/// ~/Library/Application Support/Harmonizer/Presets.json
public final class PresetStore: @unchecked Sendable {
    public static let shared = PresetStore()
    public static let changed = Notification.Name("HarmonizerPresetsChanged")

    private let url: URL
    private let lock = NSLock()

    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Harmonizer/Presets.json")
        try? FileManager.default.createDirectory(at: self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    public var presets: [UserPreset] {
        lock.lock(); defer { lock.unlock() }
        guard let d = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([UserPreset].self, from: d)) ?? []
    }

    private func write(_ list: [UserPreset]) {
        lock.lock()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(list).write(to: url, options: .atomic)
        lock.unlock()
        NotificationCenter.default.post(name: PresetStore.changed, object: nil)
    }

    /// Save (replacing a preset with the same name).
    public func save(name: String, spec: TransitionSpec) {
        var s = spec
        s.locked = nil
        s.mixOn = nil; s.outNudge = 0; s.inNudge = 0; s.inDelay = nil
        var list = presets.filter { $0.name != name }
        list.append(UserPreset(name: name, spec: s))
        write(list)
    }

    public func delete(_ id: UUID) { write(presets.filter { $0.id != id }) }
}
