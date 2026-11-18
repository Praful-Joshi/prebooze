import AVFoundation
import CLame
import Foundation

// MARK: - Project → mix

extension MixProject {
    /// Inputs and layout for the included tracks (optionally only positions
    /// `subrange`, 0-based), or nil while any track lacks analysis.
    public func mixLayout(subrange: ClosedRange<Int>? = nil, cache: AnalysisCache = .shared)
        -> (inputs: [MixInput], layout: MixLayout)? {
        guard let allPlans = plans(cache: cache), let infos = mixInfos(cache: cache), !infos.isEmpty else { return nil }
        let gains = loudnessGains(infos.map(\.analysis.loudness), trimsDb: infos.map { $0.track.trimDb ?? 0 })
        let inputs = infos.enumerated().map { i, info in
            MixInput(id: info.track.id, url: info.track.url, grid: info.grid, gain: gains[i], variant: info.variant,
                     stemHash: info.track.contentHash)
        }
        let r = subrange.map { max(0, $0.lowerBound)...min(infos.count - 1, $0.upperBound) } ?? 0...(infos.count - 1)
        let subInputs = Array(inputs[r])
        var subPlans = Array(allPlans[r.lowerBound..<r.upperBound])
        if r.lowerBound > 0 {
            // The first exported track starts at its own beginning: re-plan so
            // its outgoing window doesn't depend on a mix-in we left out.
            subPlans = planTransitions(grids: subInputs.map(\.grid), structures: infos[r].map(\.structure),
                                       ids: subInputs.map(\.id), specs: subPlans.map(\.spec),
                                       defaults: transitionDefaults)
        }
        return (subInputs, MixLayout(inputs: subInputs, plans: subPlans,
                                     echoTailBars: TransitionConfig.shared.defaults.echoTailBars))
    }
}

// MARK: - Export

public struct ExportOptions: Sendable {
    public var wav = true
    public var mp3 = true
    /// Included-track positions to export (0-based), nil = the whole set.
    public var subrange: ClosedRange<Int>?
    /// Only the transitions, each with lead bars either side, joined by 1 s of silence.
    public var transitionsOnly = false
    public var leadBars = 8

    public init() {}
}

public struct ExportResult: Sendable {
    public let folder: URL
    public let seconds: Double
    public let files: [URL]
}

public enum ExportError: Error, LocalizedError {
    case notReady, nothingToWrite, encoder(String)
    public var errorDescription: String? {
        switch self {
        case .notReady: "Some tracks aren't analysed yet."
        case .nothingToWrite: "Choose WAV and/or MP3."
        case let .encoder(why): "Export failed: \(why)"
        }
    }
}

/// Streams 24-bit WAV and/or 320 kbps MP3 as chunks arrive.
final class MixWriter {
    private var wav: AVAudioFile?
    private let wavBuffer: AVAudioPCMBuffer
    private var lame: OpaquePointer?
    private var mp3: FileHandle?
    private var mp3Buffer: [UInt8]
    private let chunk: Int

    init(wavURL: URL?, mp3URL: URL?, chunk: Int) throws {
        self.chunk = chunk
        let format = AVAudioFormat(standardFormatWithSampleRate: mixSampleRate, channels: 2)!
        wavBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk))!
        mp3Buffer = [UInt8](repeating: 0, count: Int(1.25 * Double(chunk)) + 7200)
        if let wavURL {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: mixSampleRate,
                                           AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 24,
                                           AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            wav = try AVAudioFile(forWriting: wavURL, settings: settings, commonFormat: .pcmFormatFloat32,
                                  interleaved: false)
        }
        if let mp3URL {
            guard let gf = lame_init() else { throw ExportError.encoder("LAME init") }
            lame_set_in_samplerate(gf, Int32(mixSampleRate))
            lame_set_num_channels(gf, 2)
            lame_set_brate(gf, 320)
            lame_set_quality(gf, 2)
            guard lame_init_params(gf) >= 0 else { throw ExportError.encoder("LAME params") }
            lame = gf
            FileManager.default.createFile(atPath: mp3URL.path, contents: nil)
            mp3 = try FileHandle(forWritingTo: mp3URL)
        }
    }

    func write(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, _ n: Int) throws {
        if let wav {
            wavBuffer.frameLength = AVAudioFrameCount(n)
            wavBuffer.floatChannelData![0].update(from: l, count: n)
            wavBuffer.floatChannelData![1].update(from: r, count: n)
            try wav.write(from: wavBuffer)
        }
        if let lame, let mp3 {
            let bytes = mp3Buffer.withUnsafeMutableBufferPointer {
                lame_encode_buffer_ieee_float(lame, l, r, Int32(n), $0.baseAddress, Int32($0.count))
            }
            guard bytes >= 0 else { throw ExportError.encoder("MP3 encode (\(bytes))") }
            try mp3.write(contentsOf: Data(mp3Buffer[0..<Int(bytes)]))
        }
    }

    func finish() throws {
        if let lame, let mp3 {
            let bytes = mp3Buffer.withUnsafeMutableBufferPointer {
                lame_encode_flush(lame, $0.baseAddress, Int32($0.count))
            }
            if bytes > 0 { try mp3.write(contentsOf: Data(mp3Buffer[0..<Int(bytes)])) }
            try mp3.close()
            lame_close(lame)
            self.lame = nil
        }
        wav = nil   // closes the file
    }
}

private func timestamp(_ frames: Int) -> String {
    let s = Int(Double(frames) / mixSampleRate)
    return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
}

extension MixProject {
    /// Render the mix (or a range / the transitions only) into `folder`:
    /// mix.wav, mix.mp3, tracklist.txt, mix.cue and transitions.json.
    public func exportMix(to folder: URL, options: ExportOptions, cache: AnalysisCache = .shared,
                          progress: (Double, String) -> Void = { _, _ in }) throws -> ExportResult {
        guard options.wav || options.mp3 else { throw ExportError.nothingToWrite }
        guard let (_, layout) = mixLayout(subrange: options.subrange, cache: cache) else { throw ExportError.notReady }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let wavURL = options.wav ? folder.appendingPathComponent("mix.wav") : nil
        let mp3URL = options.mp3 ? folder.appendingPathComponent("mix.mp3") : nil
        let chunk = 1 << 16
        let writer = try MixWriter(wavURL: wavURL, mp3URL: mp3URL, chunk: chunk)
        let engine = MixEngine(layout: layout)
        let titles = layout.decks.map { d in tracks.first { $0.id == d.id }?.displayName ?? d.url.lastPathComponent }

        // What to render: the whole timeline, or each transition with lead bars.
        var ranges: [Range<Int>] = []
        var marks: [(Int, String)] = []
        if options.transitionsOnly {
            for w in layout.windows {
                let out = layout.decks[w.index], inc = layout.decks[w.index + 1]
                let lo = max(w.globalStart - Int(Double(options.leadBars) * out.grid.barLength), out.bodyStart)
                let hi = min(w.globalEnd + Int(Double(options.leadBars) * inc.grid.barLength), inc.bodyEnd)
                ranges.append(lo..<max(hi, lo + 1))
            }
        } else {
            ranges = [0..<layout.length]
        }
        let total = ranges.reduce(0) { $0 + $1.count } + (options.transitionsOnly ? ranges.count * Int(mixSampleRate) : 0)
        var written = 0
        let silence = [Float](repeating: 0, count: Int(mixSampleRate))
        for (k, range) in ranges.enumerated() {
            if options.transitionsOnly {
                marks.append((written, "\(titles[k]) → \(titles[k + 1])"))
            }
            try engine.renderOffline(range, chunk: chunk) { l, r, n in
                try writer.write(l, r, n)
                written += n
                progress(Double(written) / Double(max(total, 1)), options.transitionsOnly
                         ? "Transition \(k + 1) of \(ranges.count)"
                         : "Track \(min(layout.decks.lastIndex { $0.globalStart <= written } ?? 0, layout.decks.count - 1) + 1) of \(layout.decks.count)")
            }
            if options.transitionsOnly {
                try silence.withUnsafeBufferPointer { try writer.write($0.baseAddress!, $0.baseAddress!, $0.count) }
                written += silence.count
            }
        }
        try writer.finish()
        if !options.transitionsOnly {
            marks = zip(layout.trackStarts, titles).map { ($0, $1) }
        }

        let tracklist = marks.map { "\(timestamp($0.0)) \($0.1)" }.joined(separator: "\n") + "\n"
        try tracklist.write(to: folder.appendingPathComponent("tracklist.txt"), atomically: true, encoding: .utf8)
        var cue = ["FILE \"\(options.wav ? "mix.wav" : "mix.mp3")\" \(options.wav ? "WAVE" : "MP3")"]
        for (n, (frame, title)) in marks.enumerated() {
            let secs = Double(frame) / mixSampleRate
            let mm = Int(secs) / 60, ss = Int(secs) % 60, ff = Int((secs - floor(secs)) * 75)
            cue += [String(format: "  TRACK %02d AUDIO", n + 1),
                    "    TITLE \"\(title.replacingOccurrences(of: "\"", with: "'"))\"",
                    String(format: "    INDEX 01 %02d:%02d:%02d", mm, ss, ff)]
        }
        try (cue.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("mix.cue"),
                                                       atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let specs = layout.windows.map { w in
            ["from": titles[w.index], "to": titles[w.index + 1], "bars": "\(w.plan.bars)",
             "outBars": "\(w.plan.outStartBar + 1)-\(w.plan.outEndBar)",
             "inBars": "\(w.plan.inStartBar + 1)-\(w.plan.inEndBar)", "inDelayBeats": w.plan.inDelay, "preset": w.spec.preset,
             "spec": String(data: (try? encoder.encode(w.spec)) ?? Data(), encoding: .utf8) ?? ""]
        }
        try JSONSerialization.data(withJSONObject: specs, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("transitions.json"))
        progress(1, "Done")
        let files = [wavURL, mp3URL].compactMap { $0 } + ["tracklist.txt", "mix.cue", "transitions.json"]
            .map { folder.appendingPathComponent($0) }
        return ExportResult(folder: folder, seconds: Double(written) / mixSampleRate, files: files)
    }
}
