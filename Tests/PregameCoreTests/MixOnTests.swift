import Foundation
import XCTest
@testable import PregameCore

final class MixOnTests: XCTestCase {
    let sr = 48000.0
    func grid(bars: Int) -> TrackGrid {
        TrackGrid(frames: Int(Double(bars) * 4 * 60 / 120 * sr) + 100, sampleRate: sr, firstBeat: 0, bpm: 120)
    }
    func structure(_ g: TrackGrid, _ s: [(Int, SectionLabel)], phrase: Int = 0, confidence: Double = 0.9) -> TrackStructure {
        TrackStructure(sections: s.map { Section($0.0, $0.1) }, bars: g.bars, confidence: confidence,
                       phraseOffset: phrase, firstBeat: g.firstBeat, bpm: g.bpm, sampleRate: g.sampleRate)
    }
    func spec(_ bars: Int = 16, _ mode: MixOnMode? = nil) -> TransitionSpec {
        var s = TransitionConfig.shared.spec(preset: "Smooth Blend")
        s.bars = bars
        s.mixOn = mode
        return s
    }
    func plan(_ mode: MixOnMode, _ structures: [TrackStructure?], bars: Int = 16) -> TransitionPlan {
        var d = TransitionDefaults()
        d.mixOn = mode
        return planTransitions(grids: [grid(bars: 100), grid(bars: 100)], structures: structures,
                               ids: [UUID(), UUID()], specs: [spec(bars)], defaults: d)[0]
    }

    lazy var outS = structure(grid(bars: 100), [(0, .intro), (16, .drop), (48, .breakdown), (64, .drop), (84, .outro)])
    lazy var inS = structure(grid(bars: 100), [(0, .intro), (24, .build), (32, .drop), (64, .breakdown), (88, .outro)],
                             phrase: 4)

    func testBarsAndPhrase() {
        let b = plan(.bars, [outS, inS])
        XCTAssertEqual([b.outStartBar, b.outEndBar, b.inStartBar], [80, 96, 0])
        let p = plan(.phrase, [outS, inS])
        XCTAssertEqual([p.outStartBar, p.outEndBar, p.inStartBar], [80, 96, 4])
    }

    func testSongStructure() {
        // Leaves at the outro (84); the incoming drop (32) lands as the window ends.
        let p = plan(.structure, [outS, inS])
        XCTAssertEqual([p.outStartBar, p.outEndBar, p.inStartBar, p.inEndBar], [84, 100, 16, 32])
        XCTAssertEqual(p.mode, .structure)
        XCTAssertTrue(p.warnings.isEmpty, "\(p.warnings)")
    }

    func testIntroOutro() {
        let p = plan(.introOutro, [outS, inS])
        XCTAssertEqual([p.outStartBar, p.inStartBar], [84, 0])
    }

    func testShortIntroWarns() {
        let shortIntro = structure(grid(bars: 100), [(0, .intro), (4, .drop), (88, .outro)])
        let p = plan(.structure, [outS, shortIntro])
        XCTAssertEqual(p.inStartBar, 0)
        XCTAssertTrue(p.warnings.contains { $0.contains("only 4 bars") })
    }

    func testLowConfidenceFallsBackToPhrase() {
        let unclear = structure(grid(bars: 100), [(0, .intro), (16, .drop), (84, .outro)], confidence: 0.3)
        let p = plan(.structure, [outS, unclear])
        XCTAssertEqual(p.mode, .phrase)
        XCTAssertTrue(p.warnings.contains { $0.contains("unclear on the incoming") })
        XCTAssertEqual(plan(.structure, [outS, nil]).mode, .phrase)
    }

    func testPerTransitionOverrideAndNudges() {
        var s = spec(16, .bars)
        s.outNudge = -8
        s.inNudge = 2
        var d = TransitionDefaults()
        d.mixOn = .structure
        let p = planTransitions(grids: [grid(bars: 100), grid(bars: 100)], structures: [outS, inS],
                                ids: [UUID(), UUID()], specs: [s], defaults: d)[0]
        XCTAssertEqual([p.outEndBar, p.inStartBar], [88, 2])
    }

    func testOldProjectsKeepNudgedTransitionsOnBars() throws {
        var p = MixProject()
        var nudged = spec()
        nudged.outNudge = 4
        p.transitions = ["a>b": nudged, "b>c": spec()]
        var json = try JSONSerialization.jsonObject(with: p.fileData()) as! [String: Any]
        var defaults = json["transitionDefaults"] as! [String: Any]
        defaults.removeValue(forKey: "mixOn")
        json["transitionDefaults"] = defaults
        let old = try MixProject.fromFileData(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.transitionDefaults.mixOn, .structure)
        XCTAssertEqual(old.transitions["a>b"]?.mixOn, .bars)
        XCTAssertNil(old.transitions["b>c"]?.mixOn)
        // A current project round-trips unchanged.
        XCTAssertEqual(try MixProject.fromFileData(p.fileData()), p)
    }
}

final class VariantTests: XCTestCase {
    let sr = 48000.0

    func testLoopsKeepTheGridExact() {
        // Clicks on every beat at 125 BPM (beat = 23040 frames): looped bars must keep clicks on the grid.
        let bpm = 125.0, beat = 60 / bpm * sr
        let y = Clicks.track(bpm: bpm, beats: 64, offset: 1000)
        let audio = DecodedAudio(sampleRate: sr, left: y, right: y)
        let bar = 4 * beat
        let v = AudioVariant(loops: [.init(start: 1000, length: 2 * bar, repeats: 2),
                                     .init(start: 1000 + 8 * bar, length: bar, repeats: 3)])
        let out = v.apply(to: audio, nativeRate: sr)
        XCTAssertEqual(Double(out.frames), Double(y.count) + 7 * bar, accuracy: 2)
        let onsets = Clicks.onsets(out.left)
        let first = Double(onsets.first ?? 0)   // onsets are burst peaks, a fixed offset in
        let expected = (0..<(64 + 28)).map { first + Double($0) * beat }
        XCTAssertEqual(onsets.count, expected.count)
        for (o, e) in zip(onsets, expected) { XCTAssertEqual(Double(o), e, accuracy: 60) }
        XCTAssertEqual(v.virtualFrame(1000 + 9 * bar), 1000 + 9 * bar + 7 * bar)
        XCTAssertEqual(v.virtualFrame(1000 + bar), 1000 + bar)
        XCTAssertEqual(v.sourceFrame(ofVirtual: 1000 + 5 * bar), 1000 + bar, accuracy: 1e-6)   // 3rd play of the 2-bar loop
        XCTAssertEqual(v.sourceFrame(ofVirtual: 1000 + 16 * bar), 1000 + 9 * bar, accuracy: 1e-6)
    }

    func testPitchShiftKeepsTimingAndMovesPitch() {
        // 440 Hz bursts on the beat; +3 semitones → ~523 Hz, onsets unchanged.
        let y = Clicks.track(bpm: 120, beats: 16, offset: 4800, freq: 440)
        let audio = DecodedAudio(sampleRate: sr, left: y, right: y)
        let out = AudioVariant(semitones: 3).apply(to: audio, nativeRate: sr)
        XCTAssertEqual(out.frames, y.count)
        let a = Clicks.onsets(y), b = Clicks.onsets(out.left)
        XCTAssertEqual(a.count, b.count)
        for (p, q) in zip(a, b) { XCTAssertEqual(Double(p), Double(q), accuracy: 0.006 * sr) }
        // Pitch from zero crossings of a sustained tone.
        let tone = (0..<Int(sr)).map { Float(sin(2 * .pi * 440 * Double($0) / sr)) * 0.5 }
        let shifted = AudioVariant(semitones: 3).apply(to: DecodedAudio(sampleRate: sr, left: tone, right: tone),
                                                       nativeRate: sr).left
        var crossings = 0
        for i in 12000..<36000 where (shifted[i - 1] < 0) != (shifted[i] < 0) { crossings += 1 }
        XCTAssertEqual(Double(crossings) / 2 / 0.5, 440 * pow(2, 3.0 / 12), accuracy: 4)
    }

    func testMixInfoAppliesEditsAndLoops() throws {
        let cache = AnalysisCache(directory: TestFiles.tempDir())
        let g = TrackGrid(frames: Int(100 * 2 * sr), sampleRate: sr, firstBeat: 500, bpm: 120)
        let s = TrackStructure(sections: [Section(0, .intro), Section(16, .drop), Section(84, .outro)],
                               bars: g.bars, confidence: 0.9, phraseOffset: 0, firstBeat: 500, bpm: 120, sampleRate: sr)
        let a = TrackAnalysis(sampleRate: sr, frames: g.frames, key: parseKey("8A"), bpm: 120, mixxxFirstBeat: 500,
                              firstBeat: 500, beatConfidence: 0.9, barEnergy: [], loudness: -9, structure: s)
        cache.store("h", a, WaveformSummary(peak: [], low: [], mid: [], high: []))
        var t = ProjectTrack(path: "/x.mp3", title: "x", artist: "")
        t.contentHash = "h"
        t.analysedKey = a.key
        t.introLoop = TrackLoop(bars: 8, repeats: 1)
        t.outroLoop = TrackLoop(bars: 4, repeats: 2)
        t.keyShift = 2
        XCTAssertEqual(t.key?.description, "10A")
        let info = try XCTUnwrap(cache.mixInfo(t))
        XCTAssertEqual(info.grid.bars, g.bars + 16)
        XCTAssertEqual(info.structure?.sections.map(\.startBar), [0, 24, 92])
        XCTAssertEqual(info.introLoopBars, 0..<16)
        XCTAssertEqual(info.outroLoopBars, 92..<104)
        XCTAssertEqual(info.variant.semitones, 2)

        // Edits: bar 1 one beat later, corrected sections, a cue.
        var e = TrackEdits()
        e.downbeatShift = 1
        var fixed = s
        fixed.relabel(1, .build)
        e.structure = fixed
        e.cues[2] = 10
        cache.setEdits("h", e)
        XCTAssertEqual(AnalysisCache(directory: cache.directory).edits("h"), e)
        t.introLoop = nil; t.outroLoop = nil
        let edited = try XCTUnwrap(cache.mixInfo(t))
        XCTAssertEqual(edited.grid.firstBeat, 500 + 24000, accuracy: 1e-6)
        XCTAssertEqual(edited.structure?.sections[1].label, .build)
        XCTAssertEqual(edited.cueFrames[2] ?? 0, 10 * sr, accuracy: 1e-6)
    }
}

final class KeyShiftTests: XCTestCase {
    func track(_ name: String, _ key: String, _ bpm: Double) -> ProjectTrack {
        var t = ProjectTrack(path: "/music/\(name).mp3", title: name, artist: "A")
        t.analysedKey = parseKey(key)
        t.analysedBpm = bpm
        return t
    }

    func testSuggestsSmallestFixAndAppliesEverywhere() throws {
        var p = MixProject()
        p.tracks = [track("one", "8A", 124), track("two", "3A", 124), track("three", "3A", 124)]
        let before = p.transitions()
        XCTAssertGreaterThanOrEqual(before[0].label.colour.rank, 2)
        // Shifting "one" keeps two→three intact; shifting "two" would break it.
        let s = try XCTUnwrap(p.suggestKeyShift(forTransition: 0))
        XCTAssertEqual(s.trackTitle, "one")
        XCTAssertLessThanOrEqual(s.label.colour.rank, 1)
        p.tracks[0].keyShift = s.shift
        XCTAssertEqual(p.tracks[0].key, s.key)
        XCTAssertLessThanOrEqual(p.transitions()[0].label.colour.rank, 1)
        XCTAssertNil(p.suggestKeyShift(forTransition: 0), "only for clashing transitions")
        // Harmonize uses the shifted key but never changes shifts.
        let (h, _) = try p.harmonized(with: p.settings)
        XCTAssertEqual(h.tracks.first { $0.title == "one" }?.keyShift, s.shift)
    }
}

final class DelayAndLockTests: XCTestCase {
    let sr = mixSampleRate
    func audio(_ y: [Float]) -> DecodedAudio { DecodedAudio(sampleRate: sr, left: y, right: y) }

    func testSyncedDelayEntersOnTheBeatLater() throws {
        // Silent outgoing, clicks on the incoming: the first incoming click lands
        // 6 beats into the window and the rest stay on the window's beats.
        let b = Clicks.track(bpm: 126, beats: 192, offset: 0.5 * sr, freq: 3000)
        let silent = [Float](repeating: 0, count: b.count)
        let ga = TrackGrid(frames: b.count, sampleRate: sr, firstBeat: 0.3 * sr, bpm: 120)
        let gb = TrackGrid(frames: b.count, sampleRate: sr, firstBeat: 0.5 * sr, bpm: 126)
        var spec = TransitionConfig.shared.spec(preset: "Smooth Blend")
        spec.lanes = ["volume": LaneSettings(.volume, shape: .none)]
        spec.inDelay = 6.4                       // rounded to whole beats when synced
        let p = planTransitions(grids: [ga, gb], ids: [UUID(), UUID()], specs: [spec], defaults: TransitionDefaults())[0]
        XCTAssertEqual(p.inDelay, 6)
        XCTAssertEqual(p.inEndBeat, p.inStartBar * 4 + p.beats - 6)
        let s = try TransitionSession(plan: p, outAudio: audio(silent), inAudio: audio(b), outGrid: ga, inGrid: gb,
                                      gains: (1, 1), leadBars: 2)
        XCTAssertEqual(Double(s.inSpan.lowerBound), s.outBeats[6], accuracy: 1)
        let (l, _) = s.renderAll()
        let onsets = Clicks.onsets(Array(l[s.outSpan]))
        let start = Double(s.outSpan.lowerBound)
        let first = Double(try XCTUnwrap(onsets.first)) + start
        XCTAssertEqual(first, s.outBeats[6] + 120, accuracy: 0.01 * sr)   // onsets report the burst peak (+120)
        for (k, o) in onsets.enumerated() where 6 + k < s.outBeats.count - 1 {
            XCTAssertEqual(Double(o) + start, s.outBeats[6 + k] + 120, accuracy: 0.01 * sr)
        }
    }

    func testSequentialDelayLeavesAGap() throws {
        let a = Clicks.track(bpm: 125, beats: 160, freq: 1000)
        let g = TrackGrid(frames: a.count, sampleRate: sr, firstBeat: 0, bpm: 125)
        var spec = TransitionConfig.shared.spec(preset: "Quick Cut")
        spec.inDelay = 8
        XCTAssertFalse(spec.sync)
        let p = planTransitions(grids: [g, g], ids: [UUID(), UUID()], specs: [spec], defaults: TransitionDefaults())[0]
        let s = try TransitionSession(plan: p, outAudio: audio(a), inAudio: audio(a), outGrid: g, inGrid: g,
                                      gains: (1, 1), leadBars: 2)
        let beat = 60 / 125 * sr
        XCTAssertEqual(Double(s.inSpan.lowerBound - s.outSpan.upperBound), 8 * beat, accuracy: 1)
        let (l, _) = s.renderAll()
        // Silent from shortly after the outgoing span until the incoming span.
        let gap = l[(s.outSpan.upperBound + Int(0.1 * sr))..<(s.inSpan.lowerBound - 10)]
        XCTAssertLessThan(gap.map(abs).max() ?? 1, 1e-3)
        XCTAssertGreaterThan(l[s.inSpan].map(abs).max() ?? 0, 0.1)
    }

    func testLockedTransitionKeepsItsPlaceAndWarns() {
        let g = TrackGrid(frames: Int(100 * 2 * sr), sampleRate: sr, firstBeat: 0, bpm: 120)
        var spec = TransitionConfig.shared.spec(preset: "Smooth Blend")
        let free = planTransitions(grids: [g, g], ids: [UUID(), UUID()], specs: [spec], defaults: TransitionDefaults())[0]
        spec.locked = LockedPlacement(bars: 8, outStartBar: 40, inStartBar: 3, inDelay: 2)
        var d = TransitionDefaults()
        d.mixOn = .bars
        let p = planTransitions(grids: [g, g], ids: [UUID(), UUID()], specs: [spec], defaults: d)[0]
        XCTAssertNotEqual(free.outStartBar, 40)
        XCTAssertEqual([p.bars, p.outStartBar, p.outEndBar, p.inStartBar], [8, 40, 48, 3])
        XCTAssertEqual(p.inDelay, 2)
        XCTAssertTrue(p.warnings.isEmpty)
        let short = TrackGrid(frames: Int(44 * 2 * sr), sampleRate: sr, firstBeat: 0, bpm: 120)
        let q = planTransitions(grids: [short, g], ids: [UUID(), UUID()], specs: [spec], defaults: d)[0]
        XCTAssertTrue(q.warnings.contains { $0.contains("Locked transition no longer fits") })
    }
}

final class LockedChainTests: XCTestCase {
    func track(_ name: String, _ key: String, _ bpm: Double) -> ProjectTrack {
        var t = ProjectTrack(path: "/music/\(name).mp3", title: name, artist: "A")
        t.analysedKey = parseKey(key)
        t.analysedBpm = bpm
        return t
    }

    func project() -> MixProject {
        var p = MixProject()
        p.tracks = [track("a", "8A", 124), track("b", "3B", 128), track("c", "9A", 124), track("d", "8B", 124),
                    track("e", "4B", 128), track("f", "10A", 125)]
        // Lock a clashing pair b→c and the chain d→e→f.
        for (x, y) in [(1, 2), (3, 4), (4, 5)] {
            var s = TransitionConfig.shared.spec(preset: "Echo Out")
            s.locked = LockedPlacement(bars: 4, outStartBar: 10, inStartBar: 0, inDelay: 0)
            p.transitions[MixProject.pairKey(p.tracks[x].id, p.tracks[y].id)] = s
        }
        return p
    }

    func testHarmonizeKeepsLockedChains() throws {
        let p = project()
        XCTAssertEqual(p.lockedChains.map { $0.map(\.title).joined() }, ["a", "bc", "def"])
        let (h, r) = try p.harmonized(with: p.settings)
        let order = h.included.map(\.title).joined()
        XCTAssertTrue(order.contains("bc") && order.contains("def"), order)
        XCTAssertEqual(r.cost, h.summary().totalCost, accuracy: 1e-9)
        // The locked transitions survive (same pair keys).
        XCTAssertEqual(h.transitions.values.filter(\.isLocked).count, 3)
    }

    func testMovingOneTrackMovesItsChain() {
        var p = project()
        let ids = p.tracks.map(\.id)
        p.moveTracks([ids[4]], before: ids[0])           // e drags d and f with it
        XCTAssertEqual(p.tracks.map(\.title).joined(), "defabc")
        p.moveTracks([ids[0]], before: ids[2])           // dropping inside b→c lands before b
        XCTAssertEqual(p.tracks.map(\.title).joined(), "defabc")
        p.moveTracks([ids[0]], before: nil)
        XCTAssertEqual(p.tracks.map(\.title).joined(), "defbca")
        XCTAssertEqual(p.lockedTransitionKeys(touching: [ids[2]]), [MixProject.pairKey(ids[1], ids[2])])
    }
}
