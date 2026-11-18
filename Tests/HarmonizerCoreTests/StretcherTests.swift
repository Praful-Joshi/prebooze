import Foundation
import XCTest
@testable import HarmonizerCore

enum Clicks {
    /// Click track: short 1 kHz bursts on every beat.
    static func track(bpm: Double, beats: Int, sr: Double = 48000, offset: Double = 0,
                      freq: Double = 1000) -> [Float] {
        let per = 60 / bpm * sr
        var y = [Float](repeating: 0, count: Int(offset + Double(beats) * per + sr * 0.5))
        for b in 0..<beats {
            let s = Int((offset + Double(b) * per).rounded())
            for i in 0..<240 where s + i < y.count {
                let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / 239)
                y[s + i] += Float(sin(2 * Double.pi * freq * Double(i) / sr) * w)
            }
        }
        return y
    }

    /// Onset positions: peaks of a short smoothed envelope.
    static func onsets(_ y: [Float], sr: Double = 48000, minGap: Double = 0.2) -> [Int] {
        let env = movingAverage(y.map(abs), 48)
        let top = env.max() ?? 0
        return findPeaks(env, height: top * 0.3, distance: Int(minGap * sr))
    }
}

final class StretcherTests: XCTestCase {
    func testGlideKeepsBeatsOnTargets() {
        let sr = 48000.0, beats = 64
        let y = Clicks.track(bpm: 120, beats: beats)
        let per = 60 / 120 * sr
        let n = Int(Double(beats) * per)
        let seg = Array(y[0..<n])
        let tgt = TempoGlide.beatTargets(from: 120, to: 126, beats: beats, mode: .full, sampleRate: sr)
        let src = (0...beats).map { Double($0) * per }
        let out = Stretcher.stretch([seg, seg], sampleRate: sr, sourcePoints: src, targetPoints: tgt)
        XCTAssertEqual(out[0].count, Int(tgt.last!.rounded()))
        let pk = Clicks.onsets(out[0])
        let errs = tgt.dropLast().map { t in pk.map { abs(Double($0) - t) }.min() ?? .infinity }
        // the detector peaks ~2.5 ms after a click starts; allow stretch jitter on top
        XCTAssertLessThan(errs.max()! / sr * 1000, 8.0, "max beat error \(errs.max()! / sr * 1000) ms")
    }

    func testIdentityMapIsUntouched() {
        let y: [Float] = (0..<10000).map { Float(sin(Double($0) * 0.01)) }
        let out = Stretcher.stretch([y], sampleRate: 48000, sourcePoints: [0, 10000], targetPoints: [0, 10000])
        XCTAssertEqual(out[0], y)
    }
}
