import Foundation
import XCTest
@testable import HarmonizerCore

/// The Swift engine must reproduce the retired Python engine (fixtures captured
/// from it before it was removed): key parsing, labels, costs and solver optimality.
final class EngineParityTests: XCTestCase {
    struct KeyFixture: Decodable {
        let parse: [String: String?]
        let names: [String: String]
        let classify: [String: String]
    }

    struct HarmonizeFixture: Decodable {
        struct Track: Decodable { let path: String; let key: String; let bpm: Double }
        struct Case: Decodable {
            struct S: Decodable {
                let mode: String
                let key_bpm_slider: Double
                let bpm_tolerance: Double
                let tempo_direction: String
                let half_double: Bool
            }
            let settings: S
            let matrix: [[Double]]
            let heuristic_cost: Double
            let exact12_cost: Double
        }
        let tracks: [Track]
        let cases: [Case]
    }

    func fixture<T: Decodable>(_ name: String) throws -> T {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")!
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    func testKeyParsingNamesAndLabels() throws {
        let f: KeyFixture = try fixture("keys")
        for (text, expected) in f.parse {
            XCTAssertEqual(parseKey(text)?.description, expected, "parse \(text)")
        }
        for (camelot, name) in f.names {
            XCTAssertEqual(parseKey(camelot)?.name, name)
        }
        XCTAssertEqual(f.classify.count, 576)
        for (pair, label) in f.classify {
            let parts = pair.split(separator: ">").map(String.init)
            XCTAssertEqual(classify(parseKey(parts[0])!, parseKey(parts[1])!).label, label, pair)
        }
    }

    func testCostMatricesAndSolverMatchPython() throws {
        let sets: [String: HarmonizeFixture] = try fixture("harmonize")
        XCTAssertFalse(sets.isEmpty)
        for (name, set) in sets where !set.tracks.isEmpty {
            let keys = set.tracks.map { parseKey($0.key)! }
            let bpms = set.tracks.map(\.bpm)
            for c in set.cases {
                var s = HarmonizeSettings()
                s.mode = MixMode(rawValue: c.settings.mode)!
                s.keyBpmSlider = c.settings.key_bpm_slider
                s.bpmTolerance = c.settings.bpm_tolerance
                s.tempoDirection = TempoDirection(rawValue: c.settings.tempo_direction)!
                s.halfDouble = c.settings.half_double
                let m = CostMatrix.build(keys: keys, bpms: bpms, settings: s)
                for i in 0..<m.n {
                    for j in 0..<m.n where i != j {
                        XCTAssertEqual(m[i, j], c.matrix[i][j], accuracy: 1e-5, "\(name) \(i)->\(j)")
                    }
                }
                // Exact solver: same optimum as Python on the first 12 tracks, locked ends.
                let sub = Array(0..<min(12, m.n))
                var sm = CostMatrix(n: sub.count, values: [])
                sm.values = sub.flatMap { i in sub.map { j in m[i, j] } }
                let exact = try solve(sm, first: 0, last: sub.count - 1)
                XCTAssertEqual(exact.cost, c.exact12_cost, accuracy: 1e-6, "\(name) exact")
                // Heuristic: at least as good as Python's (small slack for search luck).
                let h = try solve(m, timeBudget: 60, seed: 42)
                XCTAssertFalse(h.hitTimeLimit)
                XCTAssertEqual(Set(h.order), Set(0..<m.n))
                XCTAssertLessThanOrEqual(h.cost, c.heuristic_cost * 1.01 + 0.5,
                                         "\(name) \(c.settings) heuristic")
            }
        }
    }

    func testLocksAndSmallCases() throws {
        var m = CostMatrix(n: 2, values: [.infinity, 1, 2, .infinity])
        XCTAssertEqual(try solve(m, first: 1).order, [1, 0])
        XCTAssertEqual(try solve(m, last: 1).order, [0, 1])
        m = CostMatrix(n: 1, values: [.infinity])
        XCTAssertEqual(try solve(m).order, [0])
        XCTAssertThrowsError(try solve(m, first: 0, last: 0))
    }
}
