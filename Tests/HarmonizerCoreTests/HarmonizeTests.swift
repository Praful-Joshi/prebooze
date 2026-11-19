import Foundation
import XCTest
@testable import HarmonizerCore

/// Keys typed or read from tags, and the label each Transition gets.
final class KeyAndLabelTests: XCTestCase {
    func testParsesEveryNotation() {
        let cases: [String: String?] = [
            "8A": "8A", "08b": "8B", "12A": "12A",                        // Camelot
            "Am": "8A", "A minor": "8A", "Amin": "8A", "C": "8B", "C major": "8B", "AM": "11B",
            "G": "9B", "Em": "9A", "Bm": "10A", "Gm": "6A", "Ebm": "2A", "Abm": "1A", "B": "1B",
            "Ab": "4B", "G#": "4B", "F#m": "11A", "Gbm": "11A", "C♯m": "12A", "D♭": "3B", "Ebmaj": "5B",
            "1m": "8A", "1d": "8B", "6m": "1A", "12d": "7B",              // Open Key
            "8A/Am": "8A", "Am - 8A": "8A",                               // two notations in one tag
            "": nil, "xyz": nil, "13A": nil, "H": nil,
        ]
        for (text, expected) in cases {
            XCTAssertEqual(parseKey(text)?.description, expected, "parse \(text)")
        }
    }

    func testNamesEveryKey() {
        let names = ["G#m", "Ebm", "Bbm", "Fm", "Cm", "Gm", "Dm", "Am", "Em", "Bm", "F#m", "C#m",
                     "B", "F#", "Db", "Ab", "Eb", "Bb", "F", "C", "G", "D", "A", "E"]
        for (i, name) in names.enumerated() {
            let key = CamelotKey(i % 12 + 1, i < 12 ? "A" : "B")
            XCTAssertEqual(key.name, name)
            XCTAssertEqual(parseKey(name), key, "a key's name parses back to it")
        }
    }

    func label(_ from: String, _ to: String) -> String? {
        var p = MixProject()
        p.tracks = [from, to].map { key in
            var t = ProjectTrack(path: "/m/\(key).mp3", title: key, artist: "")
            t.analysedKey = parseKey(key)
            t.analysedBpm = 124
            return t
        }
        return p.transitions().first?.label.label
    }

    func testKnownPairsGetTheirLabel() {
        let cases = [("8A", "8A", "Perfect Match"), ("8A", "7A", "Perfect Drop"), ("8A", "9A", "Perfect Boost"),
                     ("8A", "10A", "Energy Boost"), ("8A", "8B", "Scale Change"), ("8B", "9A", "Diagonal Mix"),
                     ("8A", "7B", "Diagonal Mix"), ("8A", "3A", "Jaws Mix"), ("8B", "5A", "Mood Change"),
                     ("8A", "11B", "Mood Change"), ("8A", "2A", "Incompatible"), ("12A", "1A", "Perfect Boost"),
                     ("1B", "12B", "Perfect Drop")]
        for (a, b, expected) in cases { XCTAssertEqual(label(a, b), expected, "\(a) → \(b)") }
    }

    /// From any key, each compatible move leads to exactly one key; the other 16 clash.
    func testEveryKeyHasOneDestinationPerMove() {
        let keys = (1...12).flatMap { n in [CamelotKey(n, "A"), CamelotKey(n, "B")] }
        for from in keys {
            var counts: [String: Int] = [:]
            for to in keys { counts[label(from.description, to.description)!, default: 0] += 1 }
            XCTAssertEqual(counts, ["Perfect Match": 1, "Perfect Drop": 1, "Perfect Boost": 1, "Energy Boost": 1,
                                    "Scale Change": 1, "Diagonal Mix": 1, "Jaws Mix": 1, "Mood Change": 1,
                                    "Incompatible": 16], "from \(from)")
        }
    }
}

/// Harmonize on Mixes too big for the exact solver, with a known best order.
/// A fixed number of search rounds keeps them fast and deterministic.
final class HarmonizeTests: XCTestCase {
    func track(_ key: String, _ bpm: Double, _ n: Int) -> ProjectTrack {
        var t = ProjectTrack(path: "/m/\(n).mp3", title: "\(key) \(bpm) #\(n)", artist: "")
        t.analysedKey = parseKey(key)
        t.analysedBpm = bpm
        return t
    }

    /// Three Tracks in each minor key, at one tempo, shuffled.
    func keyLadder() -> MixProject {
        var p = MixProject()
        var rng = SeededRandom(seed: 1)
        p.tracks = (0..<36).map { track("\($0 % 12 + 1)A", 124, $0) }.shuffled(using: &rng)
        return p
    }

    /// One key, 30 tempos two BPM apart, shuffled.
    func tempoSpread(mixedKeys: Bool = false) -> MixProject {
        var p = MixProject()
        var rng = SeededRandom(seed: 2)
        p.tracks = (0..<30).map { track(mixedKeys ? "\($0 % 12 + 1)\($0 % 2 == 0 ? "A" : "B")" : "8A",
                                        100 + 2 * Double($0), $0) }.shuffled(using: &rng)
        return p
    }

    func settings(_ change: (inout HarmonizeSettings) -> Void = { _ in }) -> HarmonizeSettings {
        var s = HarmonizeSettings.defaults()
        s.rounds = 20
        s.timeBudget = .infinity   // no clock: the rounds alone bound the work
        change(&s)
        return s
    }

    func harmonize(_ p: MixProject, _ s: HarmonizeSettings) throws -> MixProject {
        let (out, _) = try p.harmonized(with: s)
        XCTAssertEqual(Set(out.tracks.map(\.id)), Set(p.tracks.map(\.id)), "every Track plays exactly once")
        XCTAssertEqual(out.tracks.count, p.tracks.count)
        return out
    }

    func labels(_ p: MixProject) -> [String] { p.transitions().map(\.label.label) }

    func testFuzzyPlaysEachKeyTogetherAndClimbsTheWheel() throws {
        let out = try harmonize(keyLadder(), settings())
        // Twelve key groups need eleven moves between them; all the rest are Perfect Matches.
        XCTAssertEqual(labels(out).filter { $0 != "Perfect Match" }.count, 11, "\(labels(out))")
        XCTAssertTrue(out.transitions().allSatisfy { $0.label.colour == .green }, "\(labels(out))")
    }

    func testMoodBoostsEnergyAtEveryTransition() throws {
        let out = try harmonize(keyLadder(), settings { $0.mode = .mood })
        XCTAssertEqual(Set(labels(out)), ["Perfect Boost"], "\(labels(out))")
    }

    func testAscendingTempoNeverDropsOrJumps() throws {
        let out = try harmonize(tempoSpread(), settings { $0.tempoDirection = .ascending })
        for t in out.transitions() {
            XCTAssertLessThanOrEqual(t.bpmDelta, 4, "jump beyond the tolerance")
            XCTAssertGreaterThanOrEqual(t.bpmDelta, -4, "drop beyond the tolerance")
        }
        XCTAssertLessThan(out.tracks.first!.bpm!, out.tracks.last!.bpm!)
    }

    func testBpmOnlyIgnoresKeysAndKeepsTempoSmooth() throws {
        let out = try harmonize(tempoSpread(mixedKeys: true), settings { $0.keyBpmSlider = 100 })
        XCTAssertTrue(out.transitions().allSatisfy { abs($0.bpmDelta) <= 4 })
        XCTAssertTrue(labels(out).contains("Incompatible"), "keys play no part")
    }

    func testOpenerCloserAndLockedChainsStayInPlace() throws {
        var p = keyLadder()
        func first(_ key: String) -> ProjectTrack { p.tracks.first { $0.key?.description == key }! }
        let opener = first("7A").id, closer = first("3A").id
        // A locked clashing pair (5A → 11A) and a locked chain (2A → 9A → 4A), both against
        // wheel order. Locked Tracks sit next to each other, as they did when they were locked.
        let pair = [first("5A"), first("11A")], chain = [first("2A"), first("9A"), first("4A")]
        let locked = Set((pair + chain).map(\.id))
        let rest = p.tracks.filter { !locked.contains($0.id) }
        p.tracks = Array(rest[..<10]) + pair + Array(rest[10..<20]) + chain + Array(rest[20...])
        for (x, y) in [(pair[0], pair[1]), (chain[0], chain[1]), (chain[1], chain[2])] {
            var spec = TransitionConfig.shared.spec(preset: "Echo Out")
            spec.locked = LockedPlacement(bars: 4, outStartBar: 10, inStartBar: 0, inDelay: 0)
            p.transitions[MixProject.pairKey(x.id, y.id)] = spec
        }
        let out = try harmonize(p, settings {
            $0.lockFirst = opener
            $0.lockLast = closer
        })
        XCTAssertEqual(out.tracks.first?.id, opener)
        XCTAssertEqual(out.tracks.last?.id, closer)
        let ids = out.tracks.map(\.id)
        for group in [pair, chain] {
            let at = try XCTUnwrap(ids.firstIndex(of: group[0].id))
            XCTAssertEqual(Array(ids[at..<(at + group.count)]), group.map(\.id), "locked Tracks stay together, in order")
        }
        XCTAssertEqual(out.transitions.values.filter(\.isLocked).count, 3)
    }

    func testSameSeedSameOrderAndAnotherSeedStillGood() throws {
        let p = keyLadder()
        let a = try harmonize(p, settings()), b = try harmonize(p, settings())
        XCTAssertEqual(a.tracks.map(\.id), b.tracks.map(\.id))
        let c = try harmonize(p, settings { $0.seed = 7 })
        XCTAssertEqual(labels(c).filter { $0 != "Perfect Match" }.count, 11)
    }

    func testTwoTracksFollowTheOpener() throws {
        var p = MixProject()
        p.tracks = [track("8A", 124, 0), track("9A", 124, 1)]
        let (out, _) = try p.harmonized(with: settings { $0.lockFirst = p.tracks[1].id })
        XCTAssertEqual(out.tracks.map(\.id), [p.tracks[1].id, p.tracks[0].id])
        XCTAssertThrowsError(try p.harmonized(with: settings {
            $0.lockFirst = p.tracks[0].id
            $0.lockLast = p.tracks[0].id
        }))
    }
}
