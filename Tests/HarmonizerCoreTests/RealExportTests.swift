import AVFoundation
import Foundation
import XCTest
@testable import HarmonizerCore

/// Exports a real set end to end. Slow and needs the music files:
/// HARMONIZER_EXPORT=/path/to/folder HARMONIZER_EXPORT_OUT=/tmp/x swift test -c release --filter RealExport
final class RealExportTests: XCTestCase {
    func testExportRealSet() throws {
        let env = ProcessInfo.processInfo.environment
        guard let folder = env["HARMONIZER_EXPORT"], let outPath = env["HARMONIZER_EXPORT_OUT"] else {
            throw XCTSkip("set HARMONIZER_EXPORT and HARMONIZER_EXPORT_OUT")
        }
        var project = MixProject()
        project.tracks = scanFolder(URL(fileURLWithPath: folder)).map(ProjectTrack.from)
        let t0 = Date()
        let analysed = ParallelMap.run(project.tracks) { t -> (String, TrackAnalysis)? in
            guard let h = try? AnalysisCache.contentHash(t.url),
                  let a = try? AnalysisCache.shared.analysis(for: t.url, hash: h) else { return nil }
            return (h, a)
        }
        for (i, r) in analysed.enumerated() { if let (h, a) = r { project.tracks[i].apply(a, hash: h) } }
        print(String(format: "REAL analysis %.1fs for %d tracks", Date().timeIntervalSince(t0), project.tracks.count))
        project = try project.harmonized(with: project.settings).0
        // Exercise M4: a key shift and both loop kinds.
        let inc = project.tracks.indices.filter { project.tracks[$0].include }
        project.tracks[inc[3]].keyShift = 1
        project.tracks[inc[5]].outroLoop = TrackLoop(bars: 4, repeats: 2)
        project.tracks[inc[6]].introLoop = TrackLoop(bars: 8, repeats: 1)
        let plans = try XCTUnwrap(project.plans())
        let modes = Dictionary(grouping: plans, by: \.mode).mapValues(\.count)
        print("REAL modes", modes.map { "\($0.key.title): \($0.value)" }.sorted().joined(separator: ", "),
              "· warnings", plans.flatMap(\.warnings).count)
        if env["HARMONIZER_PLAN_ONLY"] != nil {
            plans.flatMap(\.warnings).forEach { print("  WARN", $0) }
            plans.forEach { print("  PLAN", $0.index, $0.mode.title, $0.bars, $0.outStartBar, $0.inStartBar) }
            return
        }
        let t1 = Date()
        let result = try project.exportMix(to: URL(fileURLWithPath: outPath), options: ExportOptions())
        print(String(format: "REAL export %.1fs for %.1f min of mix", Date().timeIntervalSince(t1), result.seconds / 60))

        // Click check at every join of the real mix.
        guard let (_, layout) = project.mixLayout() else { return XCTFail("no layout") }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: outPath).appendingPathComponent("mix.wav"))
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8000)!
        var worst: (Double, Int) = (0, 0)
        let joins = layout.decks.flatMap { [$0.bodyStart, $0.bodyEnd] }.filter { $0 > 8000 && $0 < layout.length - 8000 }
        for j in joins {
            file.framePosition = AVAudioFramePosition(j - 4000)
            try file.read(into: buf, frameCount: 8000)
            let x = UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))
            let d = zip(x, x.dropFirst()).map { abs($0 - $1) }
            let typical = d.sorted()[Int(Double(d.count) * 0.99)]
            let atJoin = d[3990..<4010].max()!
            let ratio = Double(atJoin / max(typical, 1e-6))
            if ratio > worst.0 { worst = (ratio, j) }
        }
        print(String(format: "REAL worst join jump %.2f× the local 99th percentile (%d joins)", worst.0, joins.count))
        XCTAssertLessThan(worst.0, 3)
    }
}
