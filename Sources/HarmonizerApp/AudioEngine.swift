import AVFoundation
import HarmonizerCore
import os

/// Plays whichever source is current (a transition preview or the whole mix)
/// through the default output. Switching sources pauses the previous one.
final class AudioEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let current = OSAllocatedUnfairLock<(any AudioRenderable)?>(initialState: nil)
    private var source: AVAudioSourceNode!
    private var started = false

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: mixSampleRate, channels: 2)!
        source = AVAudioSourceNode(format: format) { [current] _, _, frameCount, bufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(bufferList)
            let n = Int(frameCount)
            guard abl.count >= 2,
                  let l = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            // If the UI thread holds the lock this cycle, output silence rather than block.
            let source = current.withLockIfAvailable { $0 } ?? nil
            if let source {
                source.render(frames: n, left: l, right: r)
            } else {
                l.update(repeating: 0, count: n)
                r.update(repeating: 0, count: n)
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        // When macOS changes the output (headphones off, speakers on, a new
        // default), the engine stops: move to the right device and carry on.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                               queue: .main) { [weak self] _ in self?.reroute() }
        NotificationCenter.default.addObserver(forName: AudioOutputs.changed, object: nil,
                                               queue: .main) { [weak self] _ in self?.reroute() }
        // Debug: silent playback for automated checks.
        if ProcessInfo.processInfo.environment["HARMONIZER_MUTE"] != nil { engine.mainMixerNode.outputVolume = 0 }
    }

    /// Make `source` the one that plays. The previous source is paused.
    func setSource(_ source: (any AudioRenderable)?) {
        current.withLock {
            if let old = $0, old !== source { old.pause() }
            $0 = source
        }
    }

    func isCurrent(_ source: AnyObject?) -> Bool {
        current.withLock { $0 != nil && $0 === source }
    }

    /// Start the hardware lazily (first play), so opening a project is silent.
    func ensureRunning() {
        guard !started || !engine.isRunning else { return }
        applyDevice()
        do {
            engine.prepare()
            try engine.start()
            started = true
        } catch {
            NSLog("Harmonizer: audio engine failed to start: \(error)")
        }
    }

    /// Point the output at the chosen device (or the system default).
    private func applyDevice() {
        let id = AudioOutputs.current.withLock { $0 }
        guard id != 0, engine.outputNode.auAudioUnit.deviceID != id else { return }
        do { try engine.outputNode.auAudioUnit.setDeviceID(id) } catch {
            NSLog("Harmonizer: can't switch output device: \(error)")
        }
    }

    /// The output changed: switch device and, if we were playing, restart.
    /// (Switching itself can post another configuration change; ignore those.)
    private var reroutedAt = Date.distantPast
    private func reroute() {
        guard Date().timeIntervalSince(reroutedAt) > 0.5 else { return }
        reroutedAt = Date()
        let wasRunning = started
        if engine.isRunning { engine.stop() }
        started = false
        applyDevice()
        if wasRunning { ensureRunning() }
    }

    func stop() {
        current.withLock { $0?.pause() }
        if started { engine.stop(); started = false }
    }
}
