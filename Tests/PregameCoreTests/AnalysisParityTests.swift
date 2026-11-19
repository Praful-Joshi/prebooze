import Foundation
import XCTest
@testable import PregameCore

/// Native analysis vs the key/BPM Mixxx stored for the same files.
/// Slow (decodes real music): run with PREGAME_PARITY=1 swift test --filter Parity
final class AnalysisParityTests: XCTestCase {
    struct MixxxRow: Decodable {
        let path: String
        let camelot: String?
        let bpm: Double?
    }

    func testMatchesMixxx() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PREGAME_PARITY"] == "1",
                          "set PREGAME_PARITY=1 to run")
        let url = Bundle.module.url(forResource: "Fixtures/mixxx_analysis", withExtension: "json")!
        let rows = try JSONDecoder().decode([MixxxRow].self, from: Data(contentsOf: url))
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        XCTAssertGreaterThan(rows.count, 0)

        let results = ParallelMap.run(rows) { row -> (MixxxRow, TrackAnalysis?, Double) in
            let t0 = Date()
            guard let audio = try? decodeAudio(URL(fileURLWithPath: row.path)) else { return (row, nil, 0) }
            return (row, analyse(audio).0, Date().timeIntervalSince(t0))
        }
        var keyHits = 0, bpmHits = 0, total = 0
        var misses: [String] = []
        for (row, a, _) in results {
            guard let a else { misses.append("UNDECODABLE \(row.path)"); continue }
            total += 1
            let keyOK = a.key?.description == row.camelot
            let bpmOK = abs((a.bpm ?? 0) - (row.bpm ?? -1)) <= 0.1
            keyHits += keyOK ? 1 : 0
            bpmHits += bpmOK ? 1 : 0
            if !keyOK || !bpmOK {
                misses.append(String(format: "%@  key %@ vs %@  bpm %.3f vs %.3f",
                                     (row.path as NSString).lastPathComponent,
                                     a.key?.description ?? "-", row.camelot ?? "-",
                                     a.bpm ?? 0, row.bpm ?? 0))
            }
        }
        let secs = results.map(\.2)
        print("PARITY tracks \(total)  key \(keyHits)/\(total)  bpm±0.1 \(bpmHits)/\(total)  "
              + String(format: "avg %.2fs/track", secs.reduce(0, +) / Double(max(secs.count, 1))))
        misses.forEach { print("  MISS \($0)") }
        XCTAssertGreaterThanOrEqual(Double(keyHits) / Double(total), 0.95)
        XCTAssertGreaterThanOrEqual(Double(bpmHits) / Double(total), 0.95)
    }
}
