import AVFoundation
import Foundation
import XCTest
@testable import PregameCore

final class MixEngineTests: XCTestCase {
    let sr = mixSampleRate

    func tone(_ f: Double, seconds: Double) -> [Float] {
        (0..<Int(seconds * sr)).map { Float(sin(2 * .pi * f * Double($0) / sr) * 0.4) }
    }

    /// Three tracks, a synced and a sequential transition: the whole timeline
    /// renders with no clicks at any join and the right length.
    func testWholeMixIsContinuous() throws {
        let freqs = [220.0, 277.0, 330.0], bpms = [120.0, 124.0, 126.0]
        let audio = freqs.map { tone($0, seconds: 100) }
        let urls = (0..<3).map { URL(fileURLWithPath: "/test/track\($0)") }
        let grids = (0..<3).map { TrackGrid(frames: audio[$0].count, sampleRate: sr, firstBeat: 0, bpm: bpms[$0]) }
        let ids = (0..<3).map { _ in UUID() }
        let cfg = TransitionConfig.shared
        let plans = planTransitions(grids: grids, ids: ids,
                                    specs: [cfg.spec(preset: "Smooth Blend"), cfg.spec(preset: "Echo Out")],
                                    defaults: TransitionDefaults())
        let inputs = (0..<3).map { MixInput(id: ids[$0], url: urls[$0], grid: grids[$0], gain: 1) }
        let layout = MixLayout(inputs: inputs, plans: plans)
        XCTAssertEqual(layout.decks.count, 3)
        XCTAssertEqual(layout.windows.count, 2)
        XCTAssertEqual(layout.decks[1].globalStart, layout.windows[0].globalStart)          // synced: enters at window start
        XCTAssertEqual(layout.decks[2].globalStart, layout.windows[1].globalStart + layout.windows[1].inOffset)
        let engine = MixEngine(layout: layout)
        for (k, u) in urls.enumerated() { engine.provide(DecodedAudio(sampleRate: sr, left: audio[k], right: audio[k]), for: u) }
        var out: [Float] = []
        try engine.renderOffline(0..<layout.length) { l, _, n in out.append(contentsOf: UnsafeBufferPointer(start: l, count: n)) }
        XCTAssertEqual(out.count, layout.length)
        // Jumps at every deck/window boundary stay within a pure tone's slope.
        let limit = Float(2 * Double.pi * 330 / sr * 0.8) * 1.5
        var boundaries = layout.decks.flatMap { [$0.bodyStart, $0.bodyEnd] }
        boundaries += layout.windows.flatMap { [$0.globalStart, $0.globalEnd] }
        for b in boundaries where b > 2000 && b < out.count - 2000 {
            let seg = out[(b - 2000)..<(b + 2000)]
            XCTAssertLessThan(zip(seg, seg.dropFirst()).map { abs($0 - $1) }.max()!, limit, "click near \(b)")
        }
        // Tracklist marks are in order and inside the mix.
        XCTAssertEqual(layout.trackStarts.count, 3)
        XCTAssertTrue(zip(layout.trackStarts, layout.trackStarts.dropFirst()).allSatisfy { $0 < $1 })
    }

    func testRealtimeMatchesOfflineRender() throws {
        let a = tone(220, seconds: 60), b = tone(330, seconds: 60)
        let g = TrackGrid(frames: a.count, sampleRate: sr, firstBeat: 0, bpm: 125)
        let ids = [UUID(), UUID()]
        let urls = [URL(fileURLWithPath: "/t/a"), URL(fileURLWithPath: "/t/b")]
        let plans = planTransitions(grids: [g, g], ids: ids, specs: [TransitionConfig.shared.spec(preset: "Filter Blend")],
                                    defaults: TransitionDefaults())
        let layout = MixLayout(inputs: (0..<2).map { MixInput(id: ids[$0], url: urls[$0], grid: g, gain: 1) }, plans: plans)
        func engine() -> MixEngine {
            let e = MixEngine(layout: layout)
            e.provide(DecodedAudio(sampleRate: sr, left: a, right: a), for: urls[0])
            e.provide(DecodedAudio(sampleRate: sr, left: b, right: b), for: urls[1])
            return e
        }
        var offline: [Float] = []
        try engine().renderOffline(0..<layout.length) { l, _, n in offline.append(contentsOf: UnsafeBufferPointer(start: l, count: n)) }
        let rt = engine()
        try rt.prepare(0..<layout.length, evictOthers: false)
        rt.seek(to: 0); rt.play()
        var live: [Float] = [], l = [Float](repeating: 0, count: 512), r = l
        while live.count < layout.length {
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                rt.render(frames: 512, left: lp.baseAddress!, right: rp.baseAddress!) } }
            live.append(contentsOf: l)
        }
        let n = layout.length
        let diff = zip(offline.prefix(n), live.prefix(n)).map { abs($0 - $1) }.max()!
        XCTAssertLessThan(diff, 1e-5)
    }
}

final class ExportTests: XCTestCase {
    func writeKickTrack(_ url: URL, bpm: Double, seconds: Double) throws {
        let sr = 44100.0, per = 60 / bpm * sr
        let n = Int(seconds * sr)
        var y = [Float](repeating: 0, count: n)
        var b = 0.0
        while Int(0.25 * sr + b * per) < n {
            let s = Int(0.25 * sr + b * per)
            for i in 0..<Int(0.15 * sr) where s + i < n {
                let t = Double(i) / sr
                y[s + i] += Float(sin(2 * .pi * 55 * t) * exp(-t * 25) * 0.7)
                y[s + i] += Float(sin(2 * .pi * 440 * Double(s + i) / sr) * 0.05)
            }
            b += 1
        }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        y.withUnsafeBufferPointer {
            buf.floatChannelData![0].update(from: $0.baseAddress!, count: n)
            buf.floatChannelData![1].update(from: $0.baseAddress!, count: n)
        }
        let f = try AVAudioFile(forWriting: url, settings: fmt.settings)
        try f.write(from: buf)
    }

    func testProjectExportWritesEverything() throws {
        let dir = TestFiles.tempDir()
        let cache = AnalysisCache(directory: dir.appendingPathComponent("cache"))
        var project = MixProject()
        for (k, bpm) in [124.0, 125.0, 126.0].enumerated() {
            let url = dir.appendingPathComponent("t\(k).wav")
            try writeKickTrack(url, bpm: bpm, seconds: 75)
            var t = ProjectTrack(path: url.path, title: "Track \(k)", artist: "Test")
            let hash = try AnalysisCache.contentHash(url)
            t.apply(try cache.analysis(for: url, hash: hash), hash: hash)
            t.analysedKey = parseKey(["8A", "9A", "9A"][k])
            project.tracks.append(t)
        }
        XCTAssertNotNil(project.plans(cache: cache))
        let out = dir.appendingPathComponent("export")
        var steps = 0
        let result = try project.exportMix(to: out, options: ExportOptions(), cache: cache) { _, _ in steps += 1 }
        XCTAssertGreaterThan(steps, 1)
        let wav = try AVAudioFile(forReading: out.appendingPathComponent("mix.wav"))
        XCTAssertEqual(wav.fileFormat.sampleRate, mixSampleRate)
        XCTAssertEqual(Double(wav.length) / mixSampleRate, result.seconds, accuracy: 0.01)
        XCTAssertGreaterThan(result.seconds, 120)   // three 75 s tracks minus overlaps
        let mp3 = try AVAudioFile(forReading: out.appendingPathComponent("mix.mp3"))
        XCTAssertEqual(Double(mp3.length) / mp3.fileFormat.sampleRate, result.seconds, accuracy: 0.2)
        let tracklist = try String(contentsOf: out.appendingPathComponent("tracklist.txt"), encoding: .utf8)
        XCTAssertEqual(tracklist.split(separator: "\n").count, 3)
        XCTAssertTrue(tracklist.hasPrefix("00:00:00 Test - Track 0"))
        XCTAssertTrue(try String(contentsOf: out.appendingPathComponent("mix.cue"), encoding: .utf8).contains("TRACK 03"))
        // Transitions-only reel is shorter; a range export covers two tracks.
        var opts = ExportOptions(); opts.transitionsOnly = true; opts.mp3 = false
        let reel = try project.exportMix(to: dir.appendingPathComponent("reel"), options: opts, cache: cache)
        XCTAssertLessThan(reel.seconds, result.seconds)
        opts = ExportOptions(); opts.subrange = 1...2; opts.mp3 = false
        let part = try project.exportMix(to: dir.appendingPathComponent("part"), options: opts, cache: cache)
        XCTAssertLessThan(part.seconds, result.seconds)
        XCTAssertGreaterThan(part.seconds, 75)
    }
}
