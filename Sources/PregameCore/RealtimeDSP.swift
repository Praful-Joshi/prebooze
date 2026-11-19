import Foundation

/// Allocation-free per-sample processors used by the real-time and offline mixer.

/// Biquad with Float state (coefficients from `Biquad`).
struct BiquadState {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var z1: Float = 0, z2: Float = 0

    init(_ c: Biquad) {
        b0 = Float(c.b0); b1 = Float(c.b1); b2 = Float(c.b2); a1 = Float(c.a1); a2 = Float(c.a2)
    }

    @inline(__always) mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1  // transposed direct form II
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    mutating func reset() { z1 = 0; z2 = 0 }
}

/// 3-band DJ EQ: Linkwitz-Riley 4th-order crossovers at 200 Hz and 2.5 kHz.
/// The low band also passes through the 2.5 kHz crossover's all-pass, so with
/// all gains at 1 the three bands sum to a flat (all-pass) response.
struct ThreeBandEQ {
    private var lp1a, lp1b, hp1a, hp1b: BiquadState        // 200 Hz split
    private var lp2a, lp2b, hp2a, hp2b: BiquadState        // 2.5 kHz split of the rest
    private var apLa, apLb, apHa, apHb: BiquadState        // 2.5 kHz all-pass on the low band

    init(sampleRate: Double) {
        let lo = BiquadState(Biquad.lowpass(200, sampleRate: sampleRate))
        let hi = BiquadState(Biquad.highpass(200, sampleRate: sampleRate))
        let lo2 = BiquadState(Biquad.lowpass(2500, sampleRate: sampleRate))
        let hi2 = BiquadState(Biquad.highpass(2500, sampleRate: sampleRate))
        lp1a = lo; lp1b = lo; hp1a = hi; hp1b = hi
        lp2a = lo2; lp2b = lo2; hp2a = hi2; hp2b = hi2
        apLa = lo2; apLb = lo2; apHa = hi2; apHb = hi2
    }

    @inline(__always) mutating func process(_ x: Float, low gl: Float, mid gm: Float, high gh: Float) -> Float {
        let lowRaw = lp1b.process(lp1a.process(x))
        let low = apLb.process(apLa.process(lowRaw)) + apHb.process(apHa.process(lowRaw))
        let rest = hp1b.process(hp1a.process(x))
        let mid = lp2b.process(lp2a.process(rest))
        let high = hp2b.process(hp2a.process(rest))
        return gl * low + gm * mid + gh * high
    }

    mutating func reset() {
        lp1a.reset(); lp1b.reset(); hp1a.reset(); hp1b.reset()
        lp2a.reset(); lp2b.reset(); hp2a.reset(); hp2b.reset()
        apLa.reset(); apLb.reset(); apHa.reset(); apHb.reset()
    }
}

/// Resonant state-variable filter (Simper/Cytomic). One knob: 0.5 = open,
/// above = high-pass rising to 8 kHz, below = low-pass falling to 200 Hz.
struct DJFilter {
    private var ic1: Float = 0, ic2: Float = 0
    private var a1: Float = 1, a2: Float = 0, a3: Float = 0, k: Float = 1.4
    private var mode: Int = 0   // 0 = open, 1 = high-pass, -1 = low-pass
    let sampleRate: Double

    init(sampleRate: Double) { self.sampleRate = sampleRate }

    mutating func set(value: Double, resonance: Double) {
        let d = value - 0.5
        if abs(d) < 0.002 { mode = 0; return }
        let fc = d > 0 ? 20 * pow(400, d * 2) : 20000 * pow(0.01, -d * 2)
        mode = d > 0 ? 1 : -1
        let g = tan(Double.pi * min(fc, sampleRate * 0.45) / sampleRate)
        let q = max(0.5, resonance)
        let kk = 1 / q
        let aa1 = 1 / (1 + g * (g + kk))
        a1 = Float(aa1); a2 = Float(g * aa1); a3 = Float(g * g * aa1); k = Float(kk)
    }

    @inline(__always) mutating func process(_ x: Float) -> Float {
        let v3 = x - ic2
        let v1 = a1 * ic1 + a2 * v3
        let v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2 * v1 - ic1
        ic2 = 2 * v2 - ic2
        switch mode {
        case 1: return x - k * v1 - v2
        case -1: return v2
        default: return x
        }
    }

    mutating func reset() { ic1 = 0; ic2 = 0 }
}

/// Stereo feedback delay (wet only).
final class EchoBus {
    private var bufL: [Float], bufR: [Float]
    private var pos = 0
    var delay: Int
    var feedback: Float
    var wet: Float

    init(maxDelay: Int, delay: Int, feedback: Float, wet: Float) {
        bufL = [Float](repeating: 0, count: max(maxDelay, 1))
        bufR = bufL
        self.delay = min(max(delay, 1), max(maxDelay, 1))
        self.feedback = feedback
        self.wet = wet
    }

    @inline(__always) func process(sendL: Float, sendR: Float) -> (Float, Float) {
        let n = bufL.count
        var read = pos - delay
        if read < 0 { read += n }
        let dl = bufL[read], dr = bufR[read]
        bufL[pos] = sendL + feedback * dl
        bufR[pos] = sendR + feedback * dr
        pos += 1
        if pos == n { pos = 0 }
        return (dl * wet, dr * wet)
    }

    func reset() {
        for i in bufL.indices { bufL[i] = 0; bufR[i] = 0 }
        pos = 0
    }
}

/// Look-ahead peak limiter with a hard ceiling as the last line of defence.
final class Limiter {
    private let ceiling: Float
    private var delayL: [Float], delayR: [Float]
    private var pos = 0
    private var env: Float = 0
    private let attack: Float, release: Float

    init(sampleRate: Double, ceilingDb: Double = -1) {
        ceiling = Float(pow(10, ceilingDb / 20))
        let look = max(1, Int(0.0025 * sampleRate))
        delayL = [Float](repeating: 0, count: look)
        delayR = delayL
        attack = Float(1 - exp(-1 / (0.0005 * sampleRate)))
        release = Float(1 - exp(-1 / (0.08 * sampleRate)))
    }

    @inline(__always) func process(_ l: Float, _ r: Float) -> (Float, Float) {
        let peak = max(abs(l), abs(r))
        env += (peak > env ? attack : release) * (peak - env)
        let gain = env > ceiling ? ceiling / env : 1
        let dl = delayL[pos], dr = delayR[pos]
        delayL[pos] = l
        delayR[pos] = r
        pos += 1
        if pos == delayL.count { pos = 0 }
        return (max(-ceiling, min(ceiling, dl * gain)), max(-ceiling, min(ceiling, dr * gain)))
    }

    func reset() {
        for i in delayL.indices { delayL[i] = 0; delayR[i] = 0 }
        pos = 0
        env = 0
    }
}

/// Freeverb-style reverb send (8 damped combs + 4 all-passes per channel,
/// right channel offset for width). Tunings scaled from 44.1 kHz.
final class ReverbBus {
    private struct Comb {
        var buf: [Float]; var pos = 0; var store: Float = 0
        @inline(__always) mutating func process(_ x: Float, feedback: Float, damp: Float) -> Float {
            let y = buf[pos]
            store = y * (1 - damp) + store * damp
            buf[pos] = x + store * feedback
            pos += 1; if pos == buf.count { pos = 0 }
            return y
        }
    }
    private struct AllPass {
        var buf: [Float]; var pos = 0
        @inline(__always) mutating func process(_ x: Float) -> Float {
            let b = buf[pos]
            buf[pos] = x + b * 0.5
            pos += 1; if pos == buf.count { pos = 0 }
            return b - x
        }
    }
    private var combsL: [Comb], combsR: [Comb], allL: [AllPass], allR: [AllPass]
    var wet: Float = 0.35
    private let feedback: Float = 0.84, damp: Float = 0.25

    init(sampleRate: Double) {
        let k = sampleRate / 44100
        let combs = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617], alls = [556, 441, 341, 225]
        func n(_ v: Int, _ spread: Int) -> Int { max(1, Int(Double(v + spread) * k)) }
        combsL = combs.map { Comb(buf: [Float](repeating: 0, count: n($0, 0))) }
        combsR = combs.map { Comb(buf: [Float](repeating: 0, count: n($0, 23))) }
        allL = alls.map { AllPass(buf: [Float](repeating: 0, count: n($0, 0))) }
        allR = alls.map { AllPass(buf: [Float](repeating: 0, count: n($0, 23))) }
    }

    @inline(__always) func process(sendL: Float, sendR: Float) -> (Float, Float) {
        let input = (sendL + sendR) * 0.015
        var l: Float = 0, r: Float = 0
        for i in combsL.indices {
            l += combsL[i].process(input, feedback: feedback, damp: damp)
            r += combsR[i].process(input, feedback: feedback, damp: damp)
        }
        for i in allL.indices { l = allL[i].process(l); r = allR[i].process(r) }
        return (l * wet, r * wet)
    }

    func reset() {
        for i in combsL.indices {
            combsL[i].buf = [Float](repeating: 0, count: combsL[i].buf.count); combsL[i].store = 0
            combsR[i].buf = [Float](repeating: 0, count: combsR[i].buf.count); combsR[i].store = 0
        }
        for i in allL.indices {
            allL[i].buf = [Float](repeating: 0, count: allL[i].buf.count)
            allR[i].buf = [Float](repeating: 0, count: allR[i].buf.count)
        }
    }
}

/// White-noise riser: louder and brighter as `level` rises (a high-pass
/// sweeping ~300 Hz → 8 kHz), stereo-decorrelated.
struct NoiseRiser {
    private var seedL: UInt32 = 0x1234_5678, seedR: UInt32 = 0x9E37_79B9
    private var hpL = DJFilter(sampleRate: mixSampleRate), hpR = DJFilter(sampleRate: mixSampleRate)
    static let maxGain: Float = 0.18

    mutating func set(level: Float) {
        // DJFilter: 0.5 = open, 1 = full high-pass; map the level onto its upper half.
        let v = 0.55 + 0.4 * Double(min(max(level, 0), 1))
        hpL.set(value: v, resonance: 1.2)
        hpR.set(value: v, resonance: 1.2)
    }

    @inline(__always) private static func white(_ s: inout UInt32) -> Float {
        s = s &* 1_664_525 &+ 1_013_904_223
        return Float(Int32(bitPattern: s)) / Float(Int32.max)
    }

    @inline(__always) mutating func next(level: Float) -> (Float, Float) {
        let g = NoiseRiser.maxGain * level * level
        return (hpL.process(NoiseRiser.white(&seedL)) * g, hpR.process(NoiseRiser.white(&seedR)) * g)
    }

    mutating func reset() { hpL.reset(); hpR.reset() }
}
