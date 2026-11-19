import AVFoundation
import Foundation
@testable import HarmonizerCore

/// Test audio generated in Swift, with known properties (tempo, key, energy,
/// length, section changes) for tests to assert against. Mono, played on both
/// channels. Needs no external tools.
///
///     let song = SyntheticAudio.silence(seconds: 2)
///         .then(.clicks(bpm: 124, seconds: 30).mixed(with: .chords(in: key, bpm: 124, seconds: 30)))
///         .then(.clicks(bpm: 124, seconds: 15).ramped(from: 1, to: 0.2))
///     try song.write(to: dir.appendingPathComponent("a.mp3"), tags: .init(title: "A"))
struct SyntheticAudio {
    static let defaultSampleRate = 44100.0

    let sampleRate: Double
    var samples: [Float]

    var frames: Int { samples.count }
    var seconds: Double { Double(frames) / sampleRate }
    var decoded: DecodedAudio { DecodedAudio(sampleRate: sampleRate, left: samples, right: samples) }

    // MARK: - Signals

    static func silence(seconds: Double, sampleRate: Double = defaultSampleRate) -> Self {
        Self(sampleRate: sampleRate, samples: [Float](repeating: 0, count: frameCount(seconds, sampleRate)))
    }

    /// A sine at `level` peak.
    static func tone(frequency: Double, seconds: Double, level: Float = 0.4,
                     sampleRate: Double = defaultSampleRate) -> Self {
        let n = frameCount(seconds, sampleRate)
        return Self(sampleRate: sampleRate,
                    samples: (0..<n).map { Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) * level })
    }

    /// Four-on-the-floor kick-like clicks (55 Hz thump plus a 3 kHz tick) on
    /// every beat, the first at `offset` seconds.
    static func clicks(bpm: Double, seconds: Double, offset: Double = 0, level: Float = 0.8,
                       sampleRate: Double = defaultSampleRate) -> Self {
        let n = frameCount(seconds, sampleRate)
        var y = [Float](repeating: 0, count: n)
        let beat = 60 / bpm * sampleRate
        let clickLength = Int(0.15 * sampleRate), tickLength = 200
        var b = 0
        while true {
            let start = Int((offset * sampleRate + Double(b) * beat).rounded())
            if start >= n { break }
            for i in 0..<min(clickLength, n - start) {
                let t = Double(i) / sampleRate
                var v = Float(sin(2 * .pi * 55 * t) * exp(-t * 25))
                if i < tickLength { v += Float(sin(2 * .pi * 3000 * t)) * 0.375 * Float(1 - Double(i) / Double(tickLength)) }
                y[start + i] += v * level
            }
            b += 1
        }
        return Self(sampleRate: sampleRate, samples: y)
    }

    /// A cadence that defines `key`: I–IV–V–I in major, i–iv–V–i in minor (with
    /// the raised leading tone), one chord per bar, over a held tonic bass.
    /// Each voice is a sine with two softer harmonics.
    static func chords(in key: CamelotKey, bpm: Double = 120, seconds: Double, level: Float = 0.3,
                       sampleRate: Double = defaultSampleRate) -> Self {
        let tonic = key.tonicPitchClass
        let third = key.isMinor ? 3 : 4
        // Semitones above the tonic for each chord's root, third and fifth.
        let progression: [[Int]] = [[0, third, 7], [5, 5 + third, 12], [7, 11, 14], [0, third, 7]]
        let n = frameCount(seconds, sampleRate)
        let bar = Int((4 * 60 / bpm * sampleRate).rounded())
        let fade = Int(0.01 * sampleRate)
        func hz(_ semis: Int, octave: Int) -> Double {   // MIDI note → Hz
            440 * pow(2, Double(12 * (octave + 1) + tonic + semis - 69) / 12)
        }
        var y = [Float](repeating: 0, count: n)
        var start = 0, chord = 0
        while start < n {
            let length = min(bar, n - start)
            let notes = progression[chord % progression.count].map { hz($0, octave: 4) } + [hz(0, octave: 2)]
            for i in 0..<length {
                let t = Double(start + i) / sampleRate
                var v = 0.0
                for f in notes {
                    v += sin(2 * .pi * f * t) + 0.3 * sin(4 * .pi * f * t) + 0.1 * sin(6 * .pi * f * t)
                }
                let edge = Float(min(1, Double(min(i, length - 1 - i)) / Double(fade)))   // no clicks between chords
                y[start + i] = Float(v / Double(notes.count)) * level * edge
            }
            start += length
            chord += 1
        }
        return Self(sampleRate: sampleRate, samples: y)
    }

    // MARK: - Shaping

    /// Gain that moves linearly from `from` to `to` across the signal: an energy ramp.
    func ramped(from: Float, to: Float) -> Self {
        let last = Float(max(frames - 1, 1))
        var out = self
        for i in 0..<frames { out.samples[i] *= from + (to - from) * Float(i) / last }
        return out
    }

    func scaled(by gain: Float) -> Self { ramped(from: gain, to: gain) }

    /// Both signals summed; as long as the longer one.
    func mixed(with other: Self) -> Self {
        precondition(other.sampleRate == sampleRate, "sample rates differ")
        var out = frames >= other.frames ? self : other
        let shorter = frames >= other.frames ? other : self
        for i in 0..<shorter.frames { out.samples[i] += shorter.samples[i] }
        return out
    }

    /// `next` straight after this, with no crossfade: an abrupt section change.
    func then(_ next: Self) -> Self {
        precondition(next.sampleRate == sampleRate, "sample rates differ")
        return Self(sampleRate: sampleRate, samples: samples + next.samples)
    }

    // MARK: - Measuring

    func rms(fromSecond lo: Double, toSecond hi: Double) -> Float {
        let a = max(0, Int(lo * sampleRate)), b = min(frames, Int(hi * sampleRate))
        guard b > a else { return 0 }
        return (samples[a..<b].reduce(0) { $0 + $1 * $1 } / Float(b - a)).squareRoot()
    }

    // MARK: - Files

    struct Tags {
        var title: String?
        var artist: String?
        var key: CamelotKey?
        var bpm: Double?
    }

    enum WriteError: Error { case unsupportedFormat(String), tagging(URL) }

    /// Writes the format the extension names. WAV, FLAC and MP3 go through the
    /// export writer, M4A through the stem cache's AAC writer; AIFF (which the
    /// app reads but never writes) through AVAudioFile. Tags go through the
    /// app's tag writer.
    func write(to url: URL, tags: Tags? = nil) throws {
        try? FileManager.default.removeItem(at: url)
        switch url.pathExtension.lowercased() {
        case "wav": try writeWithMixWriter(wav: url)
        case "flac": try writeWithMixWriter(flac: url)
        case "mp3": try writeWithMixWriter(mp3: url)
        case "m4a":
            precondition(sampleRate == StemSeparator.sampleRate, "the AAC writer runs at \(StemSeparator.sampleRate) Hz")
            try StemCache.writeAAC(url, left: samples, right: samples)
        case "aif", "aiff": try writeAIFF(url)
        case let ext: throw WriteError.unsupportedFormat(ext)
        }
        if let tags, !writeTags(url, key: tags.key, bpm: tags.bpm, title: tags.title, artist: tags.artist) {
            throw WriteError.tagging(url)
        }
    }

    private func writeWithMixWriter(wav: URL? = nil, flac: URL? = nil, mp3: URL? = nil) throws {
        let chunk = 1 << 14
        let writer = try MixWriter(wavURL: wav, flacURL: flac, mp3URL: mp3, sampleRate: sampleRate, chunk: chunk)
        try samples.withUnsafeBufferPointer { p in
            var pos = 0
            while pos < frames {
                let n = min(chunk, frames - pos)
                try writer.write(p.baseAddress! + pos, p.baseAddress! + pos, n)
                pos += n
            }
        }
        try writer.finish()
    }

    private func writeAIFF(_ url: URL) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
                                       AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        samples.withUnsafeBufferPointer {
            buffer.floatChannelData![0].update(from: $0.baseAddress!, count: frames)
            buffer.floatChannelData![1].update(from: $0.baseAddress!, count: frames)
        }
        try file.write(from: buffer)
    }

    private static func frameCount(_ seconds: Double, _ sampleRate: Double) -> Int {
        Int((seconds * sampleRate).rounded())
    }
}

/// Scratch folders for tests.
enum TestFiles {
    static func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}
