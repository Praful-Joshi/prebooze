import Foundation
import XCTest
@testable import PregameCore

/// Prints detected structure for a folder of real tracks, for eyeballing.
/// PREGAME_STRUCTURE=~/Music/set swift test -c release --filter RealStructure
final class RealStructureTests: XCTestCase {
    func testPrintStructures() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREGAME_STRUCTURE"] else {
            throw XCTSkip("set PREGAME_STRUCTURE to a music folder")
        }
        let urls = scanFolder(URL(fileURLWithPath: (dir as NSString).expandingTildeInPath))
        let rows = ParallelMap.run(urls) { url -> String in
            guard let audio = try? decodeAudio(url) else { return "UNDECODABLE \(url.lastPathComponent)" }
            let (a, _) = analyse(audio)
            guard let s = a.structure, let bpm = a.bpm else { return "NO GRID \(url.lastPathComponent)" }
            let shift = ((a.firstBeat ?? 0) - (a.mixxxFirstBeat ?? 0)) / (60 / bpm * a.sampleRate)
            let mono = audio.mono
            let f = beatFeatures(mono, sampleRate: a.sampleRate, firstBeat: a.firstBeat ?? 0, bpm: bpm).grouped(32)
            func row(_ x: [Float]) -> String { x.map { String(format: "%4.0f", $0) }.joined() }
            let profile = "\n   bass " + row(f.bass) + "\n   off  " + row(f.offBass) + "\n   mid  " + row(f.mid) + "\n   high " + row(f.high)
            let beat = 60 / bpm * a.sampleRate
            let earliest = (a.mixxxFirstBeat ?? 0) - ((a.mixxxFirstBeat ?? 0) / beat).rounded(.down) * beat
            let bf = beatFeatures(mono, sampleRate: a.sampleRate, firstBeat: earliest, bpm: bpm).floored()
            let nov = rise(bf, half: 4)
            var score = [Double](repeating: 0, count: 4)
            let top = nov.max() ?? 0
            for k in 1..<(nov.count - 1) where nov[k] > nov[k - 1] && nov[k] >= nov[k + 1] && nov[k] >= 0.3 * top {
                score[k % 4] += Double(nov[k])
            }
            let phases = "phase scores " + score.map { String(format: "%.0f", $0) }.joined(separator: "/")
            let bb = beatFeatures(mono, sampleRate: a.sampleRate, firstBeat: a.firstBeat ?? 0, bpm: bpm).grouped(4).floored()
            let bn = novelty(bb, half: 4)
            let novs = "\n   nov  " + bn.enumerated().map { String(format: "%d:%.0f", $0.offset, $0.element) }.joined(separator: " ")
            return phases + novs + "  " + String(format: "%@\n   bars %d  phrase+%d  conf %.2f  firstBeat−mixxx %.2f beats\n   %@\n   per8:%@",
                          url.lastPathComponent, s.bars, s.phraseOffset, s.confidence, shift,
                          s.sections.map { "\($0.startBar):\($0.label.title)" }.joined(separator: " "), profile)
        }
        print(rows.sorted().joined(separator: "\n"))
    }
}

final class RealKeyShiftTiming: XCTestCase {
    func testTiming() throws {
        guard let path = ProcessInfo.processInfo.environment["PREGAME_SHIFT_FILE"] else { throw XCTSkip("opt-in") }
        let audio = try decodeAudio(URL(fileURLWithPath: path), sampleRate: mixSampleRate)
        let t0 = Date()
        let out = AudioVariant(semitones: 2).apply(to: audio, nativeRate: mixSampleRate)
        print(String(format: "SHIFT %.1f s audio in %.2f s", Double(out.frames) / mixSampleRate, Date().timeIntervalSince(t0)))
    }
}
