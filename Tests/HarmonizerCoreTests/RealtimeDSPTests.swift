import Foundation
import XCTest
@testable import HarmonizerCore

final class RealtimeDSPTests: XCTestCase {
    /// Magnitude (dB) of a filter's impulse response at frequency f.
    func magnitudeDb(_ h: [Float], _ f: Double, sr: Double = 48000) -> Double {
        var re = 0.0, im = 0.0
        for (n, v) in h.enumerated() {
            let a = 2 * Double.pi * f * Double(n) / sr
            re += Double(v) * cos(a); im -= Double(v) * sin(a)
        }
        return 20 * log10((re * re + im * im).squareRoot())
    }

    func impulse(_ process: (Float) -> Float, n: Int = 1 << 15) -> [Float] {
        (0..<n).map { process($0 == 0 ? 1 : 0) }
    }

    func testEQIsFlatAtUnityAndCutsBands() {
        var eq = ThreeBandEQ(sampleRate: 48000)
        let flat = impulse { eq.process($0, low: 1, mid: 1, high: 1) }
        for f in [30.0, 100, 200, 500, 1000, 2500, 5000, 12000, 18000] {
            XCTAssertEqual(magnitudeDb(flat, f), 0, accuracy: 0.1, "\(f) Hz")
        }
        eq.reset()
        let noBass = impulse { eq.process($0, low: 0, mid: 1, high: 1) }
        XCTAssertLessThan(magnitudeDb(noBass, 50), -20)
        XCTAssertEqual(magnitudeDb(noBass, 1000), 0, accuracy: 1.0)
        eq.reset()
        let noHigh = impulse { eq.process($0, low: 1, mid: 1, high: 0) }
        XCTAssertLessThan(magnitudeDb(noHigh, 12000), -20)
    }

    func testFilterOpenIsTransparentAndSweeps() {
        var f = DJFilter(sampleRate: 48000)
        f.set(value: 0.5, resonance: 0.9)
        XCTAssertEqual(impulse { f.process($0) }.prefix(3), [1, 0, 0])
        f.reset(); f.set(value: 1.0, resonance: 0.707)   // high-pass at 8 kHz
        let hp = impulse { f.process($0) }
        XCTAssertLessThan(magnitudeDb(hp, 500), -30)
        f.reset(); f.set(value: 0.0, resonance: 0.707)   // low-pass at 200 Hz
        let lp = impulse { f.process($0) }
        XCTAssertLessThan(magnitudeDb(lp, 5000), -30)
        XCTAssertEqual(magnitudeDb(lp, 50), 0, accuracy: 1.0)
    }

    func testEchoRepeatsAndLimiterCaps() {
        let echo = EchoBus(maxDelay: 1000, delay: 100, feedback: 0.5, wet: 1)
        var outs: [Float] = []
        for i in 0..<400 { outs.append(echo.process(sendL: i == 0 ? 1 : 0, sendR: 0).0) }
        XCTAssertEqual(outs[100], 1); XCTAssertEqual(outs[200], 0.5); XCTAssertEqual(outs[300], 0.25)
        let lim = Limiter(sampleRate: 48000, ceilingDb: -1)
        var peak: Float = 0
        for i in 0..<48000 { peak = max(peak, abs(lim.process(Float(sin(Double(i) * 0.05)) * 3, 0).0)) }
        XCTAssertLessThanOrEqual(peak, Float(pow(10, -1.0 / 20)) + 1e-6)
    }
}
