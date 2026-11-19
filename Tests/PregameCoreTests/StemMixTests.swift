import AVFoundation
import Foundation
import XCTest
@testable import PregameCore

final class StemMixTests: XCTestCase {
    let sr = mixSampleRate
    func tone(_ f: Double, _ n: Int, _ a: Double = 0.15) -> [Float] {
        (0..<n).map { Float(sin(2 * .pi * f * Double($0) / sr) * a) }
    }
    func power(at f: Double, _ seg: ArraySlice<Float>) -> Double {
        var re = 0.0, im = 0.0
        for (k, v) in seg.enumerated() {
            let ang = 2 * Double.pi * f * Double(k) / sr
            re += Double(v) * cos(ang); im += Double(v) * sin(ang)
        }
        return (re * re + im * im) / Double(seg.count * seg.count)
    }

    /// Two "tracks" whose stems are pure tones (drums 100 Hz, bass 200, vocals
    /// 400, melody 800 = track minus the rest). A spec whose stem lanes are all
    /// flat renders exactly like no stem lanes; fading the outgoing vocals
    /// removes only the vocal tone.
    func render(_ spec: TransitionSpec, sync: Bool = true) throws -> (layout: MixLayout, out: [Float]) {
        let n = Int(80 * sr)
        let stems = [tone(100, n), tone(200, n), tone(400, n)], melody = tone(800, n)
        let full = (0..<n).map { stems[0][$0] + stems[1][$0] + stems[2][$0] + melody[$0] }
        let g = TrackGrid(frames: n, sampleRate: sr, firstBeat: 0, bpm: 125)
        let ids = [UUID(), UUID()], urls = [URL(fileURLWithPath: "/s/a"), URL(fileURLWithPath: "/s/b")]
        let plans = planTransitions(grids: [g, g], ids: ids, specs: [spec], defaults: TransitionDefaults())
        let layout = MixLayout(inputs: (0..<2).map { MixInput(id: ids[$0], url: urls[$0], grid: g, gain: 1) }, plans: plans)
        let e = MixEngine(layout: layout)
        // The incoming deck is silent, so everything heard is the outgoing track.
        e.provide(DecodedAudio(sampleRate: sr, left: full, right: full), for: urls[0])
        let silent = [Float](repeating: 0, count: n)
        e.provide(DecodedAudio(sampleRate: sr, left: silent, right: silent), for: urls[1])
        for (k, kind) in [StemKind.drums, .bass, .vocals].enumerated() {
            e.provide(DecodedAudio(sampleRate: sr, left: stems[k], right: stems[k]), for: urls[0], stem: kind)
            e.provide(DecodedAudio(sampleRate: sr, left: silent, right: silent), for: urls[1], stem: kind)
        }
        var out: [Float] = []
        try e.renderOffline(0..<layout.length) { l, _, c in out.append(contentsOf: UnsafeBufferPointer(start: l, count: c)) }
        return (layout, out)
    }

    func base() -> TransitionSpec {
        var s = TransitionConfig.shared.spec(preset: "Smooth Blend")
        s.lanes = [:]
        return s
    }

    func testFlatStemLanesAreTransparent() throws {
        var flat = base()
        for k in LaneKind.stems { flat.lanes[k.rawValue] = LaneSettings(k, shape: .none) }
        let a = try render(base()).out, b = try render(flat).out
        XCTAssertEqual(a.count, b.count)
        XCTAssertLessThan(zip(a, b).map { abs($0 - $1) }.max()!, 1e-5)
    }

    func testFadingVocalsRemovesOnlyVocals() throws {
        var spec = base()
        spec.lanes[LaneKind.vocals.rawValue] = LaneSettings(.vocals, shape: .fadeOut, strength: 1)
        let (layout, out) = try render(spec)
        let w = layout.windows[0]
        let early = out[(w.globalStart - Int(2 * sr))..<(w.globalStart - Int(sr))]
        let late = out[(w.globalEnd - Int(0.6 * sr))..<(w.globalEnd - Int(0.1 * sr))]
        XCTAssertGreaterThan(power(at: 400, early), 100 * power(at: 400, late))       // vocals gone
        XCTAssertEqual(power(at: 200, late), power(at: 200, early), accuracy: power(at: 200, early) * 0.3)  // bass kept
        XCTAssertEqual(power(at: 800, late), power(at: 800, early), accuracy: power(at: 800, early) * 0.3)  // melody kept
    }

    func testEffectsStayInTheirWindow() throws {
        var spec = base()
        spec.lanes[LaneKind.noise.rawValue] = LaneSettings(.noise, shape: .crossfade, strength: 1)
        spec.lanes[LaneKind.sidechain.rawValue] = LaneSettings(.sidechain, shape: .crossfade, strength: 1)
        spec.lanes[LaneKind.reverb.rawValue] = LaneSettings(.reverb, shape: .crossfade, strength: 1)
        let plain = try render(base()).out
        let (layout, fx) = try render(spec)
        let w = layout.windows[0]
        // Untouched before the window.
        let before = (Int(sr))..<(w.globalStart - Int(sr))
        XCTAssertLessThan(before.map { abs(fx[$0] - plain[$0]) }.max()!, 1e-4)
        // Inside, the ending part differs (noise, ducking, reverb).
        let inside = (w.globalEnd - Int(sr))..<w.globalEnd
        XCTAssertGreaterThan(inside.map { abs(fx[$0] - plain[$0]) }.max()!, 0.05)
    }

    /// AAC stems written by the cache read back aligned with the source.
    func testStemCacheRoundTripStaysAligned() throws {
        let cache = StemCache(directory: TestFiles.tempDir())
        let n = Int(10 * StemSeparator.sampleRate)
        let clicks = Clicks.track(bpm: 120, beats: 18, sr: StemSeparator.sampleRate, offset: 2205)
        let x = Array(clicks.prefix(n)) + [Float](repeating: 0, count: max(0, n - clicks.count))
        let stems = (0..<4).map { _ in [x, x] }
        try cache.store("h", stems: stems)
        XCTAssertTrue(cache.has("h"))
        XCTAssertGreaterThan(cache.totalBytes, 0)
        let back = try decodeAudio(cache.url("h", .drums), sampleRate: StemSeparator.sampleRate)
        let a = Clicks.onsets(x, sr: StemSeparator.sampleRate), b = Clicks.onsets(back.left, sr: StemSeparator.sampleRate)
        XCTAssertEqual(a.count, b.count)
        for (p, q) in zip(a, b) { XCTAssertEqual(Double(p), Double(q), accuracy: 0.001 * StemSeparator.sampleRate) }
        cache.remove("h")
        XCTAssertFalse(cache.has("h"))
    }
}

final class PresetTests: XCTestCase {
    func testSaveApplyDelete() {
        let store = PresetStore(url: TestFiles.tempDir().appendingPathComponent("p.json"))
        var mine = TransitionConfig.shared.spec(preset: "Stem Swap")
        XCTAssertNotNil(mine.lane(.bassline), "built-in stem preset loads its stem lanes")
        mine.bars = 32
        mine.outNudge = 4
        mine.locked = LockedPlacement(bars: 32, outStartBar: 1, inStartBar: 0, inDelay: 0)
        store.save(name: "Long Stems", spec: mine)
        XCTAssertEqual(store.presets.map(\.name), ["Long Stems"])
        var base = TransitionConfig.shared.spec(preset: "Echo Out")
        base.mixOn = .phrase
        base.inNudge = 2
        let applied = store.presets[0].applied(to: base)
        XCTAssertEqual(applied.bars, 32)
        XCTAssertEqual(applied.preset, "Long Stems")
        XCTAssertEqual(applied.mixOn, .phrase)
        XCTAssertEqual(applied.inNudge, 2)
        XCTAssertEqual(applied.outNudge, 0)
        XCTAssertNil(applied.locked)
        store.save(name: "Long Stems", spec: base)       // same name replaces
        XCTAssertEqual(store.presets.count, 1)
        store.delete(store.presets[0].id)
        XCTAssertTrue(store.presets.isEmpty)
    }
}

/// Real songs with stems already in the cache:
/// PREGAME_STEM_PAIR="/a.mp3|/b.mp3" swift test -c release --filter RealStemMix
final class RealStemMixTests: XCTestCase {
    func testRealStemsAreTransparentAndClickFree() throws {
        guard let pair = ProcessInfo.processInfo.environment["PREGAME_STEM_PAIR"] else { throw XCTSkip("opt-in") }
        var project = MixProject()
        project.tracks = pair.split(separator: "|").map { ProjectTrack.from(URL(fileURLWithPath: String($0))) }
        for i in project.tracks.indices {
            let h = try AnalysisCache.contentHash(project.tracks[i].url)
            project.tracks[i].apply(try AnalysisCache.shared.analysis(for: project.tracks[i].url, hash: h), hash: h)
            XCTAssertTrue(StemCache.shared.has(h), "separate stems for \(project.tracks[i].title) first")
        }
        let key = project.resolvedTransitions()[0].key
        func render(_ spec: TransitionSpec?) throws -> (MixLayout, [Float]) {
            var p = project
            p.transitions[key] = spec
            let (_, layout) = try XCTUnwrap(p.mixLayout())
            let w = layout.windows[0]
            let range = max(0, w.globalStart - Int(8 * mixSampleRate))..<min(layout.length, w.globalEnd + Int(8 * mixSampleRate))
            let engine = MixEngine(layout: layout)
            var out: [Float] = []
            try engine.renderOffline(range) { l, _, n in out.append(contentsOf: UnsafeBufferPointer(start: l, count: n)) }
            return (layout, out)
        }
        var base = TransitionConfig.shared.spec(preset: "Smooth Blend")
        let (_, plain) = try render(base)
        // All four stems at 0.999 forces the stem path; with melody = track − the
        // other three, the result must be 0.999 × the plain render.
        for k in LaneKind.stems {
            var l = LaneSettings(k, shape: .none)
            l.shape = .manual
            l.out = [Breakpoint(0, 0.999), Breakpoint(1, 0.999)]
            l.inc = l.out
            base.lanes[k.rawValue] = l
        }
        let (_, flat) = try render(base)
        let diff = zip(plain, flat).map { abs(0.999 * $0 - $1) }.max()!
        print(String(format: "REALSTEM flat-vs-plain max diff %.2e", diff))
        XCTAssertLessThan(diff, 1e-3)
        // Proof the stems are really used: muting the outgoing vocals changes the window.
        var muted = TransitionConfig.shared.spec(preset: "Smooth Blend")
        var v = LaneSettings(.vocals, shape: .none)
        v.shape = .manual
        v.out = [Breakpoint(0, 0), Breakpoint(1, 0)]
        muted.lanes[LaneKind.vocals.rawValue] = v
        let (ml, mout) = try render(muted)
        let mw = ml.windows[0], m0 = max(0, mw.globalStart - Int(8 * mixSampleRate))
        let inside = (mw.globalStart - m0)..<(mw.globalStart - m0 + Int(4 * mixSampleRate))
        let rms = { (x: [Float], r: Range<Int>) in (r.map { Double(x[$0] * x[$0]) }.reduce(0, +) / Double(r.count)).squareRoot() }
        let change = rms(zip(plain, mout).map { $0 - $1 }, inside) / rms(plain, inside)
        print(String(format: "REALSTEM muting vocals changes the window by %.1f%% (rms)", change * 100))
        XCTAssertGreaterThan(change, 0.05)

        let (layout, swap) = try render(TransitionConfig.shared.spec(preset: "Stem Swap"))
        // Joins: no jump bigger than 3× the local 99th percentile of sample-to-sample movement.
        let w = layout.windows[0], start = max(0, w.globalStart - Int(8 * mixSampleRate))
        var worst = 0.0
        for j in [w.globalStart, w.globalEnd] {
            let c = j - start
            guard c > 4000, c + 4000 < swap.count else { continue }
            let d = (c - 4000..<c + 4000).map { abs(swap[$0 + 1] - swap[$0]) }
            let typical = d.sorted()[Int(Double(d.count) * 0.99)]
            worst = max(worst, Double(d[3990..<4010].max()! / max(typical, 1e-6)))
        }
        print(String(format: "REALSTEM worst join %.2f×", worst))
        XCTAssertLessThan(worst, 3)
    }
}

final class StemFileTests: XCTestCase {
    func testWritesAMixxxReadableStemFile() throws {
        let sr = 44100.0, n = Int(8 * sr)
        func tone(_ f: Double) -> [[Float]] {
            let x = (0..<n).map { Float(sin(2 * .pi * f * Double($0) / sr) * 0.2) }
            return [x, x]
        }
        let stems = [tone(100), tone(200), tone(800), tone(400)]
        let mix = [0, 1].map { c in (0..<n).map { i in stems.reduce(Float(0)) { $0 + $1[c][i] } } }
        let url = TestFiles.tempDir().appendingPathComponent("Test Song.stem.mp4")
        try StemFile.write(url, mix: mix, stems: stems, sampleRate: sr, tags: .init(title: "Test Song", artist: "Me"))

        // Five stereo AAC tracks; only the mix is enabled.
        let asset = AVURLAsset(url: url)
        let tracks = asset.tracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 5)
        XCTAssertEqual(tracks.map(\.isEnabled), [true, false, false, false, false])
        // The manifest sits at moov/udta/stem, as Mixxx looks for it.
        let d = try Data(contentsOf: url)
        let moov = try XCTUnwrap(StemFile.box(d, "moov", in: 0..<d.count))
        let udta = try XCTUnwrap(StemFile.box(d, "udta", in: moov.body))
        let stem = try XCTUnwrap(StemFile.box(d, "stem", in: udta.body))
        let json = try JSONSerialization.jsonObject(with: d[stem.body]) as! [String: Any]
        XCTAssertEqual((json["stems"] as! [[String: String]]).map { $0["name"]! }, StemFile.names)
        XCTAssertEqual(json["version"] as? Int, 1)
        // Mixxx 2.6's own walker (steminfoimporter.cpp) only handles 32-bit box sizes.
        XCTAssertEqual(mixxxManifest(d), d[stem.body])
        XCTAssertFalse(try StemFile.repair(url))
        // Each track decodes to its own content (stem 4 = vocals = 400 Hz).
        let v = try decodeTrack(tracks[4], of: asset)
        var crossings = 0
        for i in 22050..<66150 where (v[i - 1] < 0) != (v[i] < 0) { crossings += 1 }
        XCTAssertEqual(Double(crossings) / 2, 400, accuracy: 5)
    }

    /// One audio track of a multi-track file, as mono float samples.
    private func decodeTrack(_ track: AVAssetTrack, of asset: AVAsset) throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: 1,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var chunk = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            samples += chunk
        }
        XCTAssertEqual(reader.status, .completed)
        return samples
    }

    /// Mixxx's seekTillAtom: read size + type, descend on a match, else skip;
    /// it can't follow 64-bit sizes, so those count as failure here.
    private func mixxxManifest(_ d: Data) -> Data? {
        var o = 0, end = d.count
        for type in ["moov", "udta", "stem"] {
            var found = false
            while o + 8 <= end {
                let size = Int(d.readUInt32(o))
                guard size >= 8 else { return nil }
                if String(decoding: d[(o + 4)..<(o + 8)], as: UTF8.self) == type {
                    end = o + size; o += 8; found = true; break
                }
                o += size
            }
            if !found { return nil }
        }
        return d[o..<end]
    }
}

final class StemExportChainTests: XCTestCase {
    func testCacheToStemFileAddsUp() throws {
        let sr = StemSeparator.sampleRate, n = Int(6 * sr)
        func tone(_ f: Double) -> [Float] { (0..<n).map { Float(sin(2 * .pi * f * Double($0) / sr) * 0.15) } }
        let d = tone(100), b = tone(200), m = tone(800), v = tone(400)
        let full = (0..<n).map { d[$0] + b[$0] + m[$0] + v[$0] }
        let dir = TestFiles.tempDir()
        let song = dir.appendingPathComponent("song.wav")
        try StemCache.writeWAV(song, left: full, right: full, sampleRate: sr)
        let cache = StemCache(directory: dir.appendingPathComponent("stems"))
        try cache.store("h", stems: [[d, d], [b, b], [m, m], [v, v]], title: "Song")
        let (mix, stems) = try cache.stemFileAudio(source: song, hash: "h")
        // Melody is the remainder, so the four stems add back up to the mix exactly.
        let worst = (0..<n).map { i in abs(stems.reduce(Float(0)) { $0 + $1[0][i] } - mix[0][i]) }.max()!
        XCTAssertLessThan(worst, 1e-5)
        let out = dir.appendingPathComponent(StemCache.stemFileName(title: "Song", artist: "Me"))
        XCTAssertEqual(out.lastPathComponent, "Me - Song.stem.mp4")
        try StemFile.write(out, mix: mix, stems: stems, sampleRate: sr)
        XCTAssertEqual(AVURLAsset(url: out).tracks(withMediaType: .audio).count, 5)
    }
}
