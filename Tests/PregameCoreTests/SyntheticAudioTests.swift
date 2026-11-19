import Foundation
import XCTest
@testable import PregameCore

final class SyntheticAudioTests: XCTestCase {
    func testClickTrackRecoversItsBpm() {
        for bpm in [92.0, 124.0, 128.5, 140.0] {
            let (a, _) = analyse(SyntheticAudio.clicks(bpm: bpm, seconds: 40).decoded)
            XCTAssertEqual(a.bpm ?? 0, bpm, accuracy: 0.1, "\(bpm) BPM")
        }
    }

    func testClickTrackStartsAtItsOffset() {
        let audio = SyntheticAudio.clicks(bpm: 124, seconds: 30, offset: 0.731)
        let (a, _) = analyse(audio.decoded)
        XCTAssertEqual(a.firstBeat ?? 0, 0.731 * audio.sampleRate, accuracy: 0.01 * audio.sampleRate)
    }

    func testChordProgressionRecoversItsKey() throws {
        for name in ["Am", "C", "F#m", "Eb", "Bbm", "G"] {
            let key = try XCTUnwrap(parseKey(name))
            let (a, _) = analyse(SyntheticAudio.chords(in: key, bpm: 120, seconds: 32).decoded)
            XCTAssertEqual(a.key, key, name)
        }
    }

    func testSilenceHasExactLengthAndNoSignal() {
        let s = SyntheticAudio.silence(seconds: 1.5)
        XCTAssertEqual(s.frames, Int(1.5 * s.sampleRate))
        XCTAssertEqual(s.seconds, 1.5, accuracy: 1e-9)
        XCTAssertEqual(s.samples.map(abs).max(), 0)
    }

    func testEnergyRampRisesSteadily() {
        let ramp = SyntheticAudio.clicks(bpm: 120, seconds: 16).ramped(from: 0.1, to: 1)
        let quarters = (0..<4).map { ramp.rms(fromSecond: Double($0) * 4, toSecond: Double($0 + 1) * 4) }
        XCTAssertEqual(quarters, quarters.sorted(), "energy should only rise")
        XCTAssertGreaterThan(quarters[3], quarters[0] * 4)
    }

    func testSectionChangeIsAbruptAndOnTheBoundary() {
        let quiet = SyntheticAudio.tone(frequency: 220, seconds: 4).scaled(by: 0.05)
        let loud = SyntheticAudio.clicks(bpm: 120, seconds: 4).mixed(with: .chords(in: CamelotKey(8, "A"), bpm: 120, seconds: 4))
        let song = quiet.then(loud).then(.silence(seconds: 2))
        XCTAssertEqual(song.seconds, 10, accuracy: 1e-9)
        let before = song.rms(fromSecond: 3, toSecond: 4)
        let after = song.rms(fromSecond: 4, toSecond: 5)
        XCTAssertGreaterThan(after, before * 3)
        XCTAssertEqual(song.rms(fromSecond: 8, toSecond: 10), 0)
    }

    func testMixingSumsAndKeepsTheLongerLength() {
        let a = SyntheticAudio.tone(frequency: 440, seconds: 1)
        let b = SyntheticAudio.silence(seconds: 2)
        let m = a.mixed(with: b)
        XCTAssertEqual(m.frames, b.frames)
        XCTAssertEqual(Array(m.samples[0..<a.frames]), a.samples)
    }

    func testWritesEachFormatWithTagsThroughTheAppWriters() throws {
        let dir = TestFiles.tempDir()
        let audio = SyntheticAudio.tone(frequency: 440, seconds: 2)
        let tags = SyntheticAudio.Tags(title: "Ünïcode Song", artist: "Test Artist", key: parseKey("F#m"), bpm: 126)  // MP4 stores whole BPMs
        for ext in ["wav", "mp3", "flac", "m4a", "aiff"] {
            let url = dir.appendingPathComponent("song.\(ext)")
            try audio.write(to: url, tags: tags)
            let read = try XCTUnwrap(readTags(url), ext)
            XCTAssertEqual(read.title, "Ünïcode Song", ext)
            XCTAssertEqual(read.artist, "Test Artist", ext)
            XCTAssertEqual(parseKey(read.keyText), parseKey("F#m"), ext)
            XCTAssertEqual(read.bpm ?? 0, 126, accuracy: 0.01, ext)
            let back = try decodeAudio(url)
            XCTAssertEqual(Double(back.frames) / back.sampleRate, 2, accuracy: 0.1, ext)
            let backMono = SyntheticAudio(sampleRate: back.sampleRate, samples: back.mono)
            XCTAssertEqual(backMono.rms(fromSecond: 0.5, toSecond: 1.5), audio.rms(fromSecond: 0.5, toSecond: 1.5),
                           accuracy: 0.02, ext)
        }
    }

    func testWritesWithoutTags() throws {
        let url = TestFiles.tempDir().appendingPathComponent("Plain Name.flac")
        try SyntheticAudio.silence(seconds: 1).write(to: url)
        let read = try XCTUnwrap(readTags(url))
        XCTAssertEqual(read.title, "Plain Name")   // falls back to the file name
        XCTAssertNil(read.keyText)
        XCTAssertNil(read.bpm)
    }

    func testRejectsUnknownFormats() {
        let url = TestFiles.tempDir().appendingPathComponent("x.ogg")
        XCTAssertThrowsError(try SyntheticAudio.silence(seconds: 1).write(to: url))
    }

    func testWrittenClickTrackKeepsItsBpmAfterLossyEncoding() throws {
        let url = TestFiles.tempDir().appendingPathComponent("clicks.mp3")
        try SyntheticAudio.clicks(bpm: 126, seconds: 40).write(to: url)
        let (a, _) = analyse(try decodeAudio(url))
        XCTAssertEqual(a.bpm ?? 0, 126, accuracy: 0.1)
    }
}

