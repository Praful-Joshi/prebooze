import Foundation
import XCTest
@testable import HarmonizerCore

/// Stem separation needs the Demucs model weights, which aren't in the repo, so
/// these run only through scripts/test-real-music.sh.
final class StemTests: XCTestCase {
    /// Swift pipeline vs the NumPy + ONNX reference (itself 80–95 dB from
    /// PyTorch Demucs). HARMONIZER_STEM_REF=<dir with ref_in.npy, ref_out.npy>.
    func testMatchesReference() throws {
        guard let dir = ProcessInfo.processInfo.environment["HARMONIZER_STEM_REF"] else {
            throw XCTSkip("set HARMONIZER_STEM_REF")
        }
        let input = try npy(URL(fileURLWithPath: dir).appendingPathComponent("ref_in.npy"))
        let ref = try npy(URL(fileURLWithPath: dir).appendingPathComponent("ref_out.npy"))
        let n = input.count / 2
        let sep = try StemSeparator(useCoreML: false)
        let t0 = Date()
        let out = try sep.separate(left: Array(input[0..<n]), right: Array(input[n...]))
        print(String(format: "STEMS swift %.1fs for %.0fs", Date().timeIntervalSince(t0), Double(n) / 44100))
        for s in 0..<4 {
            var sig = 0.0, err = 0.0
            for c in 0..<2 {
                let base = (s * 2 + c) * n
                for i in 0..<n {
                    let r = Double(ref[base + i]); sig += r * r
                    let d = Double(out[s][c][i]) - r; err += d * d
                }
            }
            let sdr = 10 * log10(sig / max(err, 1e-12))
            print(String(format: "STEMS %@ agreement %.1f dB", StemKind(rawValue: s)!.title, sdr))
            XCTAssertGreaterThan(sdr, 40)
        }
    }

    /// Minimal .npy reader (little-endian float32, C order only).
    func npy(_ url: URL) throws -> [Float] {
        let d = try Data(contentsOf: url)
        let headerLen = Int(d[8]) | Int(d[9]) << 8
        let start = 10 + headerLen
        return d.subdata(in: start..<d.count).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

/// HARMONIZER_STEM_FILE=<audio> swift test -c release --filter StemTiming
final class StemTiming: XCTestCase {
    func testFullTrack() throws {
        guard let path = ProcessInfo.processInfo.environment["HARMONIZER_STEM_FILE"] else { throw XCTSkip("opt-in") }
        let audio = try decodeAudio(URL(fileURLWithPath: path), sampleRate: StemSeparator.sampleRate)
        var t = Date()
        let sep = try StemSeparator()
        print(String(format: "STEMTIME load %.1fs", Date().timeIntervalSince(t)))
        t = Date()
        _ = try sep.separate(left: audio.left, right: audio.right)
        let el = Date().timeIntervalSince(t), dur = Double(audio.frames) / StemSeparator.sampleRate
        print(String(format: "STEMTIME separate %.1fs for %.0fs (%.1fx realtime)", el, dur, dur / el))
    }
}
