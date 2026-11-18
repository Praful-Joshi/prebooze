import Foundation
import XCTest
@testable import HarmonizerCore

/// Makes small tagged audio files with ffmpeg (skipped if ffmpeg is missing).
enum TestAudio {
    static let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    static func make(_ url: URL, seconds: Double = 2, title: String, artist: String = "Test") throws {
        guard let ffmpeg else { throw XCTSkip("ffmpeg needed") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)",
                       "-metadata", "title=\(title)", "-metadata", "artist=\(artist)", url.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }

    static func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}

final class TagTests: XCTestCase {
    func testRoundTripAllFormats() throws {
        let dir = TestAudio.tempDir()
        for (name, key, bpm) in [("a.mp3", "Am", 124.0), ("b.flac", "C", 126.5), ("c.m4a", "F#m", 125.0),
                                 ("d.wav", "Eb", 128.0), ("e.aiff", "Gm", 122.0)] {
            let url = dir.appendingPathComponent(name)
            try TestAudio.make(url, title: name)
            XCTAssertTrue(writeTags(url, key: parseKey(key), bpm: bpm), name)
            let tags = try XCTUnwrap(readTags(url), name)
            XCTAssertEqual(parseKey(tags.keyText), parseKey(key), name)
            XCTAssertEqual(tags.bpm ?? 0, bpm, accuracy: 0.01, name)
            XCTAssertGreaterThan(tags.duration ?? 0, 1.5, name)
        }
        XCTAssertEqual(scanFolder(dir).count, 5)
        XCTAssertNil(readTags(dir.appendingPathComponent("missing.mp3")))
    }
}

final class PipelineTests: XCTestCase {
    func track(_ name: String, _ key: String, _ bpm: Double) -> ProjectTrack {
        var t = ProjectTrack(path: "/music/\(name).mp3", title: name, artist: "A")
        t.analysedKey = parseKey(key)
        t.analysedBpm = bpm
        return t
    }

    func project() -> MixProject {
        var p = MixProject()
        p.tracks = [track("one", "8A", 124), track("two", "9A", 125), track("three", "10A", 126),
                    track("four", "8B", 124), track("five", "3A", 128)]
        return p
    }

    func testHarmonizeRespectsLocksAndExclusions() throws {
        var p = project()
        p.tracks[4].include = false
        var s = p.settings
        s.lockFirst = p.tracks[2].id
        s.lockLast = p.tracks[0].id
        let (out, result) = try p.harmonized(with: s)
        XCTAssertEqual(result.method, "exact")
        XCTAssertEqual(out.included.first?.id, p.tracks[2].id)
        XCTAssertEqual(out.included.last?.id, p.tracks[0].id)
        XCTAssertEqual(out.tracks.last?.id, p.tracks[4].id)   // excluded stays at the end
        XCTAssertEqual(out.transitions().count, 3)
        XCTAssertEqual(out.lastRun?.cost ?? -1, out.summary().totalCost, accuracy: 1e-9)
    }

    func testOverridesAndProblems() throws {
        var p = project()
        p.tracks[1].analysedKey = nil
        XCTAssertEqual(p.problems, ["two.mp3"])
        XCTAssertThrowsError(try p.harmonized(with: p.settings))
        p.tracks[1].keyOverride = parseKey("Em")
        XCTAssertTrue(p.problems.isEmpty)
        XCTAssertEqual(p.tracks[1].key?.description, "9A")
        XCTAssertTrue(p.tracks[1].isOverridden)
    }

    func testCsvAndM3u() throws {
        var p = project()
        p.settings.lockFirst = p.tracks[0].id
        let rows = CSV.parse(p.csv())
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows[0]["locked"], "first")
        XCTAssertEqual(rows[0]["transition_to_next"], "Perfect Boost")
        XCTAssertEqual(rows[0]["key_name"], "Am")
        XCTAssertEqual(rows[4]["transition_to_next"], "")
        let m3u = p.m3u8().split(separator: "\n")
        XCTAssertEqual(m3u.first, "#EXTM3U")
        XCTAssertEqual(m3u[2], "/music/one.mp3")
    }

    func testMatchTracklist() {
        let tracks = [ProjectTrack(path: "/m/Echo.wav", title: "Echo", artist: ""),
                      ProjectTrack(path: "/m/Charlie.m4a", title: "Charlie", artist: "Test"),
                      ProjectTrack(path: "/m/Bravo.flac", title: "Bravo", artist: "Test"),
                      ProjectTrack(path: "/m/Delta.mp3", title: "Delta", artist: "Test")]
        let r = matchTracklist("1. Test - Echo\n2. Charlie\n3) bravo.flac\nSomething Else Entirely",
                               tracks: tracks)
        XCTAssertEqual(r.matched, [tracks[0].id, tracks[1].id, tracks[2].id])
        XCTAssertEqual(r.unmatched, ["Something Else Entirely"])
        XCTAssertEqual(similarity("abcd", "bcde"), 0.75, accuracy: 1e-9)
    }

    func testImportOldRun() throws {
        let set = TestAudio.tempDir()
        let run = set.appendingPathComponent("harmonized/2026-09-26_151803_mood")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let csv = """
        position,locked,title,artist,filename,path,duration,key_detected,key_used,key_name,bpm_detected,bpm_used,overridden,transition_to_next,transition_colour,bpm_delta_to_next,cost_to_next
        1,first,One,A,one.mp3,/nowhere/one.mp3,3:00,8A,8B,C,124.0,124.0,yes,Perfect Match,green,0,0
        2,,"Two, Too",A,two.mp3,/nowhere/two.mp3,3:00,9A,9A,Em,125.0,126.0,yes,,,,
        """
        try csv.write(to: run.appendingPathComponent("reordered.csv"), atomically: true, encoding: .utf8)
        try #"{"settings": {"mode": "mood", "key_bpm_slider": 30, "bpm_tolerance": 3.5, "tempo_direction": "ascending", "half_double": true, "seed": 7}}"#
            .write(to: run.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        try #"{"/nowhere/one.mp3 → /nowhere/two.mp3": {"preset": "Filter Blend", "bars": 8}}"#
            .write(to: set.appendingPathComponent("harmonized/transitions.json"), atomically: true, encoding: .utf8)
        let p = try MixProject.importRun(run)
        XCTAssertEqual(p.tracks.map(\.title), ["One", "Two, Too"])
        XCTAssertEqual(p.tracks[0].keyOverride?.description, "8B")
        XCTAssertNil(p.tracks[0].bpmOverride)
        XCTAssertEqual(p.tracks[1].bpmOverride, 126)
        XCTAssertEqual(p.settings.lockFirst, p.tracks[0].id)
        XCTAssertEqual(p.settings.mode, .mood)
        XCTAssertEqual(p.settings.keyBpmSlider, 30)
        XCTAssertEqual(p.settings.tempoDirection, .ascending)
        XCTAssertEqual(p.settings.seed, 7)
        XCTAssertEqual(p.importedTransitions.count, 1)
        XCTAssertThrowsError(try MixProject.importRun(set))
    }

    func testProjectCodableRoundTrip() throws {
        var p = project()
        p.tracks[0].keyOverride = parseKey("Dm")
        let back = try JSONDecoder().decode(MixProject.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back, p)
    }

    /// Regression: a harmonized (dated) project must reopen from its .hmix file.
    func testHmixFileRoundTripWithDates() throws {
        var (p, _) = try project().harmonized(with: project().settings)
        p.transitions["x>y"] = TransitionConfig.shared.spec(preset: "Echo Out")
        let back = try MixProject.fromFileData(p.fileData())
        XCTAssertEqual(back.tracks, p.tracks)
        XCTAssertEqual(back.transitions, p.transitions)
        XCTAssertEqual(back.lastRun?.date.timeIntervalSince1970 ?? 0, p.lastRun!.date.timeIntervalSince1970, accuracy: 1)
        let legacy = #"{"tracks": [], "lastRun": {"date": 700000000, "method": "exact", "cost": 1, "hitTimeLimit": false}}"#
        XCTAssertEqual(try MixProject.fromFileData(Data(legacy.utf8)).lastRun?.method, "exact")
    }
}

final class AnalysisTests: XCTestCase {
    /// Synthetic four-on-the-floor kick track at a known BPM and offset.
    func kickTrack(bpm: Double, offsetSecs: Double, bars: Int, sr: Double = 44100) -> DecodedAudio {
        let per = 60 / bpm * sr
        let n = Int(offsetSecs * sr + Double(bars * 4) * per)
        var y = [Float](repeating: 0, count: n)
        let kickLen = Int(0.15 * sr)
        for b in 0..<(bars * 4) {
            let start = Int(offsetSecs * sr + Double(b) * per)
            for i in 0..<kickLen where start + i < n {
                let t = Double(i) / sr
                y[start + i] += Float(sin(2 * .pi * 55 * t) * exp(-t * 25)) * 0.8
                if i < 200 { y[start + i] += Float(sin(2 * .pi * 3000 * t)) * 0.3 * Float(1 - Double(i) / 200) }
            }
        }
        return DecodedAudio(sampleRate: sr, left: y, right: y)
    }

    func testBpmAndBeatPhaseOnSyntheticKicks() {
        let audio = kickTrack(bpm: 124, offsetSecs: 0.731, bars: 64)
        let (a, wave) = analyse(audio)
        XCTAssertEqual(a.bpm ?? 0, 124, accuracy: 0.01)
        XCTAssertGreaterThan(a.beatConfidence, 0.9)
        XCTAssertEqual(a.firstBeat ?? 0, 0.731 * 44100, accuracy: 0.01 * 44100)  // within 10 ms
        XCTAssertEqual(a.barEnergy.count, 63, accuracy: 1)
        XCTAssertEqual(wave.peak.count, audio.frames / WaveformSummary.bucketFrames)
    }

    func testBeatUtilsRounding() {
        XCTAssertEqual(BeatUtils.roundBpmWithinRange(125.9, 126.02, 126.1), 126)
        XCTAssertEqual(BeatUtils.roundBpmWithinRange(70.4, 70.52, 70.6), 70.5)
        XCTAssertEqual(BeatUtils.roundBpmWithinRange(124.97, 125.0183, 125.06), 125)
    }

    func testCacheStoresAndReloads() throws {
        let dir = TestAudio.tempDir()
        let cache = AnalysisCache(directory: dir)
        let audio = kickTrack(bpm: 128, offsetSecs: 0.2, bars: 24)
        let (a, w) = analyse(audio)
        cache.store("abc", a, w)
        let fresh = AnalysisCache(directory: dir)
        XCTAssertEqual(fresh.cached("abc")?.bpm, a.bpm)
        XCTAssertEqual(fresh.waveform("abc")?.peak, w.peak)
        XCTAssertNil(fresh.cached("nope"))
        let file = dir.appendingPathComponent("f.bin")
        try Data("hello".utf8).write(to: file)
        XCTAssertEqual(try AnalysisCache.contentHash(file),
                       "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }
}
