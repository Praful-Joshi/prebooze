import Foundation
import XCTest
@testable import HarmonizerCore

final class StructureTests: XCTestCase {
    /// Per-bar levels from a list of (bars, bass dB, high dB) parts.
    func levels(_ parts: [(Int, Float, Float)], jitter: Float = 0.4) -> BeatFeatures {
        var f = BeatFeatures(bass: [], full: [], high: [])
        var rng = SystemRandomNumberGenerator()
        for (count, bass, high) in parts {
            for _ in 0..<count {
                let j = Float.random(in: -jitter...jitter, using: &rng)
                f.bass.append(bass + j); f.full.append(max(bass, high) + j); f.high.append(high + j)
            }
        }
        return f
    }

    func labels(_ s: [Section]) -> String { s.map { "\($0.startBar):\($0.label.rawValue)" }.joined(separator: " ") }

    func testClubTrack() {
        // 16 intro, 32 drop, 16 break (highs rise in its last 8), 32 drop, 16 outro.
        let f = levels([(16, -30, -30), (32, -12, -20), (8, -32, -28), (8, -30, -22), (32, -12, -20), (16, -30, -30)])
        let (s, offset, confidence) = detectSections(f)
        XCTAssertEqual(offset, 0)
        XCTAssertEqual(labels(s), "0:intro 16:drop 48:break 56:build 64:drop 96:outro")
        XCTAssertGreaterThan(confidence, 0.7)
    }

    func testPhraseOffset() {
        // A 4-bar pickup: every change lands on bars ≡ 4 (mod 8).
        let f = levels([(20, -30, -30), (32, -12, -20), (16, -32, -26), (32, -12, -20), (20, -30, -30)])
        let (s, offset, _) = detectSections(f)
        XCTAssertEqual(offset, 4)
        XCTAssertEqual(s.map(\.startBar), [0, 20, 52, 68, 100])
        XCTAssertEqual(s.first?.label, .intro)
        XCTAssertEqual(s.last?.label, .outro)
    }

    func testFlatTrackHasLowConfidence() {
        // No contrast: still a 16-bar way in and out for mixing, but low confidence.
        let f = levels([(96, -12, -20)], jitter: 0.3)
        let (s, _, confidence) = detectSections(f)
        XCTAssertEqual(labels(s), "0:intro 16:drop 80:outro")
        XCTAssertLessThan(confidence, 0.5)
    }

    func testDownbeatAfterPickupKick() {
        // Kicks every beat from 0.25 s. The first beat is a pickup: changes land
        // one beat later, every 8 bars (hats switch on and off).
        let sr = 22050.0, bpm = 125.0, beat = 60 / bpm * sr
        let beats = 4 * 64 + 1
        var y = [Float](repeating: 0, count: Int(0.25 * sr + Double(beats + 4) * beat))
        for b in 0..<beats {
            let s = Int(0.25 * sr + Double(b) * beat)
            for i in 0..<Int(0.08 * sr) {
                y[s + i] += Float(sin(2 * .pi * 55 * Double(i) / sr) * exp(-Double(i) / (0.03 * sr)))
            }
            let bar = (b - 1) / 4
            if b >= 1, (bar / 8) % 2 == 1 {
                for i in 0..<Int(beat) where s + i < y.count {
                    y[s + i] += 0.2 * Float.random(in: -1...1)   // noise "hats" across the beat
                }
            }
        }
        let (first, structure) = analyseStructure(y, sampleRate: sr, beatAnchor: 0.25 * sr, bpm: bpm)
        XCTAssertEqual(first, 0.25 * sr + beat, accuracy: 1)
        XCTAssertEqual(structure.phraseOffset, 0)
    }

    func testRebaseAndEdits() {
        let g = TrackGrid(frames: 48000 * 240, sampleRate: 48000, firstBeat: 1000, bpm: 120)
        var s = TrackStructure(sections: [Section(0, .intro), Section(16, .drop), Section(80, .outro)],
                               bars: g.bars, confidence: 0.8, phraseOffset: 0, firstBeat: 1000, bpm: 120,
                               sampleRate: 48000)
        // Same audio at 44.1 kHz with bar 1 one bar later: sections move one bar earlier.
        let other = TrackGrid(frames: 44100 * 240, sampleRate: 44100, firstBeat: (1000 + 96000) * 44100 / 48000,
                              bpm: 120)
        XCTAssertEqual(s.rebased(to: other).sections.map(\.startBar), [0, 15, 79])
        XCTAssertEqual(s.inserting(bars: 8, at: 0).sections.map(\.startBar), [0, 24, 88])
        s.moveBoundary(1, to: 200)
        XCTAssertEqual(s.sections[1].startBar, 79)
        s.split(at: 40, label: .breakdown)
        s.relabel(0, .build)
        XCTAssertEqual(labels(s.sections), "0:build 40:break 79:drop 80:outro")
        s.merge(2)
        XCTAssertEqual(labels(s.sections), "0:build 40:break 80:outro")
        XCTAssertTrue(s.edited)
        XCTAssertEqual(s.exitBar, 80)
        XCTAssertEqual(s.firstDrop, nil)
    }
}
