import Foundation
import XCTest
@testable import PregameCore

/// What the EQ, Filter lanes and the limiter do to a rendered Mix. The outgoing
/// Track is three tones (50 Hz low, 1 kHz mid, 12 kHz high); the incoming Track is
/// silent, so everything heard comes from the outgoing one.
final class EffectLaneTests: XCTestCase {
    let sr = mixSampleRate
    let low = 50.0, mid = 1000.0, high = 12000.0
    let level = 0.15

    func tones(seconds: Double) -> [Float] {
        (0..<Int(seconds * sr)).map { i in
            let t = Double(i) / sr
            return Float(level * (sin(2 * .pi * low * t) + sin(2 * .pi * mid * t) + sin(2 * .pi * high * t)))
        }
    }

    /// Power of one frequency in a stretch of audio, as a fraction of a full-scale sine's.
    func power(at f: Double, _ seg: ArraySlice<Float>) -> Double {
        var re = 0.0, im = 0.0
        for (k, v) in seg.enumerated() {
            let a = 2 * Double.pi * f * Double(k) / sr
            re += Double(v) * cos(a); im += Double(v) * sin(a)
        }
        return 4 * (re * re + im * im) / Double(seg.count * seg.count)
    }

    func db(_ x: Double) -> Double { 10 * log10(x) }

    /// A lane held at one value for the outgoing Track through the whole Transition.
    func held(_ kind: LaneKind, _ value: Double) -> LaneSettings {
        var l = LaneSettings(kind, shape: .none)
        l.shape = .manual
        l.out = [Breakpoint(0, value), Breakpoint(1, value)]
        return l
    }

    /// Renders from 3 s before the Transition to its end. Returns the audio just
    /// before the Transition and the second half of the Transition. (A lane's
    /// starting value already applies on the way in, so "before" is only
    /// untouched when there are no lanes.)
    func render(_ lanes: [LaneKind: LaneSettings], gain: Float = 1) throws -> (before: ArraySlice<Float>, inside: ArraySlice<Float>) {
        let a = tones(seconds: 60), silent = [Float](repeating: 0, count: a.count)
        let g = TrackGrid(frames: a.count, sampleRate: sr, firstBeat: 0, bpm: 125)
        var spec = TransitionConfig.shared.spec(preset: "Smooth Blend")
        spec.lanes = Dictionary(uniqueKeysWithValues: lanes.map { ($0.key.rawValue, $0.value) })
        let ids = [UUID(), UUID()], urls = [URL(fileURLWithPath: "/fx/a"), URL(fileURLWithPath: "/fx/b")]
        let plans = planTransitions(grids: [g, g], ids: ids, specs: [spec], defaults: TransitionDefaults())
        let layout = MixLayout(inputs: (0..<2).map { MixInput(id: ids[$0], url: urls[$0], grid: g, gain: gain) },
                               plans: plans)
        let engine = MixEngine(layout: layout)
        engine.provide(DecodedAudio(sampleRate: sr, left: a, right: a), for: urls[0])
        engine.provide(DecodedAudio(sampleRate: sr, left: silent, right: silent), for: urls[1])
        let w = layout.windows[0]
        let start = w.globalStart - Int(3 * sr)
        var out: [Float] = []
        try engine.renderOffline(start..<w.globalEnd) { l, _, n in out.append(contentsOf: UnsafeBufferPointer(start: l, count: n)) }
        let half = (w.globalEnd - w.globalStart) / 2
        return (out[Int(sr)..<Int(2.5 * sr)], out[(out.count - half + Int(0.5 * sr))..<(out.count - Int(0.5 * sr))])
    }

    /// Change in dB, against the untouched Track, of each tone inside the Transition.
    func change(_ lanes: [LaneKind: LaneSettings]) throws -> (low: Double, mid: Double, high: Double) {
        let (_, inside) = try render(lanes)
        let untouched = db(level * level)
        return (db(power(at: low, inside)) - untouched, db(power(at: mid, inside)) - untouched,
                db(power(at: high, inside)) - untouched)
    }

    func testWithoutLanesEveryBandPlaysUntouched() throws {
        let (before, inside) = try render([:])
        for f in [low, mid, high] {
            XCTAssertEqual(db(power(at: f, before)), db(level * level), accuracy: 0.2, "\(f) Hz before")
            XCTAssertEqual(db(power(at: f, inside)), db(level * level), accuracy: 0.2, "\(f) Hz inside")
        }
    }

    func testBassLaneCutsOnlyTheLows() throws {
        let c = try change([.bass: held(.bass, 0)])
        XCTAssertLessThan(c.low, -20)
        XCTAssertEqual(c.mid, 0, accuracy: 1)
        XCTAssertEqual(c.high, 0, accuracy: 1)
    }

    func testHighLaneCutsOnlyTheHighs() throws {
        let c = try change([.high: held(.high, 0)])
        XCTAssertLessThan(c.high, -20)
        XCTAssertEqual(c.low, 0, accuracy: 1)
        XCTAssertEqual(c.mid, 0, accuracy: 1)
    }

    func testFilterLaneSweepsBetweenLowAndHighPass() throws {
        let highPass = try change([.filter: held(.filter, 1)])
        XCTAssertLessThan(highPass.low, -30)
        XCTAssertLessThan(highPass.mid, -20)
        XCTAssertEqual(highPass.high, 0, accuracy: 3)
        let lowPass = try change([.filter: held(.filter, 0)])
        XCTAssertLessThan(lowPass.high, -30)
        XCTAssertEqual(lowPass.low, 0, accuracy: 1)
        let open = try change([.filter: held(.filter, 0.5)])
        XCTAssertEqual(open.low, 0, accuracy: 0.5)
        XCTAssertEqual(open.mid, 0, accuracy: 0.5)
        XCTAssertEqual(open.high, 0, accuracy: 0.5)
    }

    func testLimiterKeepsAHotTrackUnderTheCeiling() throws {
        let (before, inside) = try render([:], gain: 3)   // 1.35 peak before the limiter
        let ceiling = Float(pow(10, TransitionConfig.shared.defaults.limiterCeilingDb / 20))
        XCTAssertLessThanOrEqual((before + inside).map(abs).max()!, ceiling + 1e-6)
        XCTAssertGreaterThan(before.map(abs).max()!, ceiling * 0.9, "limited, not muted")
    }
}
