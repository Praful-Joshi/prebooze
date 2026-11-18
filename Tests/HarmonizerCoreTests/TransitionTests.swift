import Foundation
import XCTest
@testable import HarmonizerCore

final class CurveTests: XCTestCase {
    func testPresetShapes() {
        let x = stride(from: 0.0, through: 1.0, by: 0.01).map { $0 }
        for strength in [0.25, 0.5, 0.75, 1.0] {
            let l = LaneSettings(.volume, shape: .crossfade, strength: strength)
            XCTAssertEqual(evaluate(l.out, at: 0), 1); XCTAssertEqual(evaluate(l.out, at: 1), 0)
            XCTAssertEqual(evaluate(l.inc, at: 0), 0); XCTAssertEqual(evaluate(l.inc, at: 1), 1)
            // Roughly equal power through the middle.
            let mid = evaluate(l.out, at: 0.5), midIn = evaluate(l.inc, at: 0.5)
            XCTAssertEqual(mid * mid + midIn * midIn, 1, accuracy: 0.15)
            let outs = x.map { evaluate(l.out, at: $0) }
            XCTAssertTrue(zip(outs, outs.dropFirst()).allSatisfy { $0 >= $1 - 1e-12 })
        }
        let filter = LaneSettings(.filter, shape: .crossfade, strength: 1)
        XCTAssertEqual(evaluate(filter.out, at: 0), 0.5); XCTAssertEqual(evaluate(filter.out, at: 1), 1)
        XCTAssertEqual(evaluate(filter.inc, at: 0), 0); XCTAssertEqual(evaluate(filter.inc, at: 1), 0.5)
        let echo = LaneSettings(.echo, shape: .fadeOut, strength: 0.75)
        XCTAssertEqual(evaluate(echo.out, at: 0), 0); XCTAssertEqual(evaluate(echo.out, at: 1), 1)
        XCTAssertEqual(evaluate(echo.inc, at: 0.5), 0)
    }

    func testSwapLandsOnABeat() {
        let l = LaneSettings(.bass, shape: .swap, strength: 1, swap: 0.74, beats: 32)
        XCTAssertEqual(evaluate(l.out, at: 0.749), 1)
        XCTAssertEqual(evaluate(l.out, at: 0.751), 0)
        XCTAssertEqual(evaluate(l.inc, at: 0.751), 1)
    }

    func testBendShapesSegment() {
        let straight = [Breakpoint(0, 0), Breakpoint(1, 1)]
        let bent = [Breakpoint(0, 0, bend: 0.5), Breakpoint(1, 1)]
        XCTAssertEqual(evaluate(straight, at: 0.5), 0.5, accuracy: 1e-12)
        XCTAssertLessThan(evaluate(bent, at: 0.5), 0.3)
    }

    func testAutoSpecRules() {
        let cfg = TransitionConfig.shared
        let cases: [(String, TransitionColour, Double, String, TempoMode)] = [
            ("Perfect Match", .green, 1, "Long Blend", .full),
            ("Perfect Match", .green, 6, "Smooth Blend", .secondHalf),
            ("Energy Boost", .yellow, 3, "Filter Blend", .full),
            ("Jaws Mix", .blue, 0, "Echo Out", .full),
            ("Incompatible", .red, 10, "Quick Cut", .full),
        ]
        for (label, colour, gap, preset, tempo) in cases {
            let (spec, reason) = cfg.autoSpec(TransitionLabel(label: label, colour: colour), bpmGap: gap, tolerance: 4)
            XCTAssertEqual(spec.preset, preset)
            XCTAssertEqual(spec.tempo, tempo)
            XCTAssertTrue(reason.contains(preset))
        }
        XCTAssertEqual(cfg.spec(preset: "Echo Out").sync, false)
        XCTAssertNotNil(cfg.spec(preset: "Filter Blend").lane(.filter))
    }
}

final class SessionTests: XCTestCase {
    let sr = mixSampleRate

    func audio(_ y: [Float]) -> DecodedAudio { DecodedAudio(sampleRate: sr, left: y, right: y) }

    func plan(_ spec: TransitionSpec, out: TrackGrid, inc: TrackGrid) -> TransitionPlan {
        planTransitions(grids: [out, inc], ids: [UUID(), UUID()], specs: [spec], defaults: TransitionDefaults())[0]
    }

    func testSyncedGlideKeepsBothTracksOnTheBeat() throws {
        let a = Clicks.track(bpm: 120, beats: 192, offset: 0.3 * sr, freq: 1000)
        let b = Clicks.track(bpm: 126, beats: 192, offset: 0.5 * sr, freq: 3000)
        let ga = TrackGrid(frames: a.count, sampleRate: sr, firstBeat: 0.3 * sr, bpm: 120)
        let gb = TrackGrid(frames: b.count, sampleRate: sr, firstBeat: 0.5 * sr, bpm: 126)
        var spec = TransitionConfig.shared.spec(preset: "Smooth Blend")
        spec.lanes = ["volume": LaneSettings(.volume, shape: .none)]
        let p = plan(spec, out: ga, inc: gb)
        let s = try TransitionSession(plan: p, outAudio: audio(a), inAudio: audio(b), outGrid: ga, inGrid: gb,
                                      gains: (1, 1), leadBars: 2)
        let (l, _) = s.renderAll()
        let window = Array(l[s.outSpan])
        let lp = Biquad.lowpass(2000, sampleRate: sr).applyZeroPhase(window)
        let hp = Biquad.highpass(2000, sampleRate: sr).applyZeroPhase(window)
        let targets = s.outBeats.dropLast().map { $0 - Double(s.outSpan.lowerBound) }
        func nearest(_ pk: [Int]) -> [Double] { targets.map { t in Double(pk.min { abs(Double($0) - t) < abs(Double($1) - t) } ?? 0) } }
        let po = nearest(Clicks.onsets(lp)), pi = nearest(Clicks.onsets(hp))
        let flam = zip(po, pi).map { abs($0 - $1) / sr * 1000 }
        XCTAssertLessThan(flam.max()!, 5, "beats drift apart by \(flam.max()!) ms")
        let absErr = zip(po, targets).map { abs($0 - $1) / sr * 1000 }
        XCTAssertLessThan(absErr.max()!, 10)
    }

    func testJoinsAreClickFreeAndCurvesApply() throws {
        let n = Int(90 * sr)
        let tone = { (f: Double) in (0..<n).map { Float(sin(2 * .pi * f * Double($0) / self.sr) * 0.4) } }
        let a = tone(220), b = tone(330)
        let ga = TrackGrid(frames: n, sampleRate: sr, firstBeat: 0, bpm: 120)
        let gb = TrackGrid(frames: n, sampleRate: sr, firstBeat: 0, bpm: 126)
        let spec = TransitionConfig.shared.spec(preset: "Smooth Blend")
        let p = plan(spec, out: ga, inc: gb)
        let s = try TransitionSession(plan: p, outAudio: audio(a), inAudio: audio(b), outGrid: ga, inGrid: gb,
                                      gains: (1, 1), leadBars: 4)
        let (l, _) = s.renderAll()
        let maxSlope = Float(2 * Double.pi * 550 / sr * 0.8)   // two tones summed, generous
        for boundary in [s.outSpan.lowerBound, s.outSpan.upperBound] {
            let seg = l[(boundary - 2000)..<(boundary + 2000)]
            let jump = zip(seg, seg.dropFirst()).map { abs($0 - $1) }.max()!
            XCTAssertLessThan(jump, maxSlope, "click at \(boundary)")
        }
        // Volume crossfade: the start of the window is the outgoing tone, the end the incoming.
        func power(at f: Double, _ seg: ArraySlice<Float>) -> Double {
            var re = 0.0, im = 0.0
            for (k, v) in seg.enumerated() {
                let ang = 2 * Double.pi * f * Double(k) / sr
                re += Double(v) * cos(ang); im += Double(v) * sin(ang)
            }
            return re * re + im * im
        }
        let early = l[s.outSpan.lowerBound..<(s.outSpan.lowerBound + 9600)]
        let late = l[(s.outSpan.upperBound - 9600)..<s.outSpan.upperBound]
        XCTAssertGreaterThan(power(at: 220, early), 10 * power(at: 330, early))
        XCTAssertGreaterThan(power(at: 330, late), 10 * power(at: 220, late))
    }

    func testEchoOutRingsAndLiveUpdate() throws {
        let a = Clicks.track(bpm: 125, beats: 160)
        let silent = [Float](repeating: 0, count: a.count)
        let g = TrackGrid(frames: a.count, sampleRate: sr, firstBeat: 0, bpm: 125)
        let spec = TransitionConfig.shared.spec(preset: "Echo Out")
        let p = plan(spec, out: g, inc: g)
        let s = try TransitionSession(plan: p, outAudio: audio(a), inAudio: audio(silent), outGrid: g, inGrid: g,
                                      gains: (1, 1), leadBars: 2)
        XCTAssertEqual(s.outSpan.upperBound, s.inSpan.lowerBound)  // sequential: incoming starts after
        let (l, _) = s.renderAll()
        let afterOut = l[s.inSpan.lowerBound..<s.inSpan.upperBound]
        XCTAssertGreaterThan(afterOut.map(abs).max()!, 0.05, "echo should ring over the incoming span")
        var dry = spec
        dry.lanes["echo"] = nil
        s.update(spec: dry)
        let (l2, _) = s.renderAll()
        XCTAssertLessThan(l2[s.inSpan.lowerBound..<s.inSpan.upperBound].map(abs).max()!, 0.01)
    }

    func testTransportPlaysAndLoops() throws {
        let a = Clicks.track(bpm: 125, beats: 160)
        let g = TrackGrid(frames: a.count, sampleRate: sr, firstBeat: 0, bpm: 125)
        let s = try TransitionSession(plan: plan(TransitionConfig.shared.spec(preset: "Filter Blend"), out: g, inc: g),
                                      outAudio: audio(a), inAudio: audio(a), outGrid: g, inGrid: g,
                                      gains: (1, 1), leadBars: 2)
        var l = [Float](repeating: 0, count: 512), r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            s.render(frames: 512, left: lp.baseAddress!, right: rp.baseAddress!) } }
        XCTAssertEqual(s.position, 0)  // paused
        s.setLoop(1000..<3000)
        s.seek(to: 1000)
        s.play()
        for _ in 0..<10 {
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                s.render(frames: 512, left: lp.baseAddress!, right: rp.baseAddress!) } }
        }
        XCTAssertTrue((1000..<3000).contains(s.position))
    }
}

final class ProjectTransitionTests: XCTestCase {
    func testResolutionOrder() {
        var p = MixProject()
        func track(_ name: String, _ key: String) -> ProjectTrack {
            var t = ProjectTrack(path: "/m/\(name).mp3", title: name, artist: "")
            t.analysedKey = parseKey(key); t.analysedBpm = 126
            return t
        }
        p.tracks = [track("a", "8A"), track("b", "8A"), track("c", "9A")]
        var r = p.resolvedTransitions()
        XCTAssertEqual(r.map(\.spec.preset), ["Long Blend", "Smooth Blend"])
        XCTAssertFalse(r[0].spec.customised)
        // Imported tweak from the old app (path-keyed) applies until edited.
        p.importedTransitions["/m/a.mp3 → /m/b.mp3"] =
            #"{"preset": "Filter Blend", "bars": 4, "sync": true, "tempo": "full", "out_nudge": -1, "lanes": {"volume": {"curve": "crossfade", "strength": 0.5}}}"#
        r = p.resolvedTransitions()
        XCTAssertEqual(r[0].spec.preset, "Filter Blend")
        XCTAssertEqual(r[0].spec.bars, 4)
        XCTAssertEqual(r[0].spec.outNudge, -1)
        XCTAssertEqual(r[0].spec.activeLanes, [.volume])
        // A saved edit wins.
        var edited = TransitionConfig.shared.spec(preset: "Quick Cut")
        edited.customised = true
        p.transitions[r[0].key] = edited
        XCTAssertEqual(p.resolvedTransitions()[0].spec.preset, "Quick Cut")
        // Survives encoding.
        let back = try! JSONDecoder().decode(MixProject.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.transitions, p.transitions)
    }

    func testPlanSnapsAndShortens() {
        let g = TrackGrid(frames: Int(200 * mixSampleRate), sampleRate: mixSampleRate, firstBeat: 1000, bpm: 125)
        let short = TrackGrid(frames: Int(40 * mixSampleRate), sampleRate: mixSampleRate, firstBeat: 0, bpm: 125)
        let cfg = TransitionConfig.shared
        let plans = planTransitions(grids: [g, short, g], ids: [UUID(), UUID(), UUID()],
                                    specs: [cfg.spec(preset: "Smooth Blend"), cfg.spec(preset: "Long Blend")],
                                    defaults: TransitionDefaults())
        XCTAssertEqual(plans[0].outEndBar % 8, 0)
        XCTAssertLessThan(plans[1].bars, 32)
        XCTAssertFalse(plans[1].warnings.isEmpty)
        XCTAssertGreaterThanOrEqual(plans[1].outStartBar, plans[0].inEndBar)
    }

    func testLoudnessGains() {
        let g = loudnessGains([-8, -14, -20, nil], trimsDb: [0, 0, 0, 3])
        XCTAssertEqual(Double(g[0]), pow(10, -6.0 / 20), accuracy: 1e-5)
        XCTAssertEqual(Double(g[1]), 1, accuracy: 1e-6)
        XCTAssertEqual(Double(g[2]), pow(10, 6.0 / 20), accuracy: 1e-5)
        XCTAssertEqual(Double(g[3]), pow(10, 3.0 / 20), accuracy: 1e-5)
    }
}
