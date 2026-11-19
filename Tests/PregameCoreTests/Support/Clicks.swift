import Foundation
import XCTest
@testable import PregameCore

/// Short sine bursts on every beat at the mix rate, and an onset finder for
/// checking where beats land in rendered audio.
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
