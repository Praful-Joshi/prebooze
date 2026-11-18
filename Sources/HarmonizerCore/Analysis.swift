import Foundation
import QMDSP

public let analysisVersion = 4

/// Everything Harmonizer knows about one audio file, independent of any project.
public struct TrackAnalysis: Codable, Sendable {
    public var version = analysisVersion
    public var sampleRate: Double
    public var frames: Int
    public var key: CamelotKey?
    public var bpm: Double?
    /// Mixxx-style grid anchor (frame), for reference.
    public var mixxxFirstBeat: Double?
    /// Bar 1, beat 1 (frame): the earliest downbeat, phase from kick onsets.
    public var firstBeat: Double?
    /// 0–1: how consistently kicks sit on the grid.
    public var beatConfidence: Double
    /// Bass RMS per bar from bar 1, normalised 0–1.
    public var barEnergy: [Float]
    /// Integrated loudness (LUFS), for level matching between tracks.
    public var loudness: Double?
    /// Sections on the grid above (bar 1 = `firstBeat`).
    public var structure: TrackStructure?

    public var duration: Double { Double(frames) / sampleRate }
    public var beatLength: Double? { bpm.map { 60 / $0 * sampleRate } }
}

/// Coloured waveform overview: per bucket, peak plus low/mid/high band RMS (0–255).
public struct WaveformSummary: Sendable {
    public static let bucketFrames = 256
    public var peak: [UInt8]
    public var low: [UInt8]
    public var mid: [UInt8]
    public var high: [UInt8]
}

// MARK: - Filters

/// Direct-form-I biquad (RBJ cookbook coefficients), double precision state.
struct Biquad {
    var b0, b1, b2, a1, a2: Double

    static func lowpass(_ freq: Double, sampleRate: Double, q: Double = 0.7071067811865476) -> Biquad {
        let w = 2 * Double.pi * freq / sampleRate
        let alpha = sin(w) / (2 * q)
        let cw = cos(w)
        let a0 = 1 + alpha
        return Biquad(b0: (1 - cw) / 2 / a0, b1: (1 - cw) / a0, b2: (1 - cw) / 2 / a0,
                      a1: -2 * cw / a0, a2: (1 - alpha) / a0)
    }

    static func highpass(_ freq: Double, sampleRate: Double, q: Double = 0.7071067811865476) -> Biquad {
        let w = 2 * Double.pi * freq / sampleRate
        let alpha = sin(w) / (2 * q)
        let cw = cos(w)
        let a0 = 1 + alpha
        return Biquad(b0: (1 + cw) / 2 / a0, b1: -(1 + cw) / a0, b2: (1 + cw) / 2 / a0,
                      a1: -2 * cw / a0, a2: (1 - alpha) / a0)
    }

    func apply(_ x: [Float]) -> [Float] {
        var y = [Float](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0..<x.count {
            let xi = Double(x[i])
            let yi = b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = xi; y2 = y1; y1 = yi
            y[i] = Float(yi)
        }
        return y
    }

    /// Zero-phase: forward then backward.
    func applyZeroPhase(_ x: [Float]) -> [Float] {
        Array(apply(Array(apply(x).reversed())).reversed())
    }
}

/// Centred moving average (like numpy.convolve(x, ones(w)/w, "same")).
func movingAverage(_ x: [Float], _ w: Int) -> [Float] {
    let n = x.count
    guard n > 0, w > 1 else { return x }
    var prefix = [Double](repeating: 0, count: n + 1)
    for i in 0..<n { prefix[i + 1] = prefix[i] + Double(x[i]) }
    let half = (w - 1) / 2
    var out = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let a = max(0, i - (w - 1 - half))
        let b = min(n, i + half + 1)
        out[i] = Float((prefix[b] - prefix[a]) / Double(w))
    }
    return out
}

/// Peaks like scipy.signal.find_peaks(x, height:, distance:).
func findPeaks(_ x: [Float], height: Float, distance: Int) -> [Int] {
    var cands: [Int] = []
    var i = 1
    while i < x.count - 1 {
        if x[i] > x[i - 1] && x[i] >= height {
            var j = i
            while j + 1 < x.count && x[j + 1] == x[i] { j += 1 }  // plateau
            if j + 1 < x.count && x[j + 1] < x[i] { cands.append((i + j) / 2) }
            i = j + 1
        } else {
            i += 1
        }
    }
    guard distance > 1 else { return cands }
    var keep = [Bool](repeating: true, count: cands.count)
    for idx in cands.indices.sorted(by: { x[cands[$0]] > x[cands[$1]] }) where keep[idx] {
        var k = idx - 1
        while k >= 0 && cands[idx] - cands[k] < distance { keep[k] = false; k -= 1 }
        k = idx + 1
        while k < cands.count && cands[k] - cands[idx] < distance { keep[k] = false; k += 1 }
    }
    return cands.indices.filter { keep[$0] }.map { cands[$0] }
}

func percentile(_ x: [Float], _ p: Double) -> Float {
    guard !x.isEmpty else { return 0 }
    let sorted = x.sorted()
    let pos = p / 100 * Double(sorted.count - 1)
    let lo = Int(pos.rounded(.down))
    let hi = min(lo + 1, sorted.count - 1)
    let f = Float(pos - Double(lo))
    return sorted[lo] * (1 - f) + sorted[hi] * f
}

// MARK: - Detectors

func detectKey(_ mono: [Float], sampleRate: Double) -> CamelotKey? {
    let chromatic = mono.withUnsafeBufferPointer {
        qm_detect_key($0.baseAddress, $0.count, sampleRate)
    }
    return CamelotKey.fromChromatic(Int(chromatic))
}

func detectRawBeats(_ mono: [Float], sampleRate: Double) -> [Double] {
    var ptr: UnsafeMutablePointer<Double>?
    let count = mono.withUnsafeBufferPointer {
        qm_detect_beats($0.baseAddress, $0.count, sampleRate, &ptr)
    }
    defer { qm_free(ptr) }
    guard count > 0, let ptr else { return [] }
    return Array(UnsafeBufferPointer(start: ptr, count: Int(count)))
}

/// Beat phase from kick onsets for a known BPM. Returns (first beat frame, confidence).
func kickPhase(_ mono: [Float], sampleRate: Double, bpm: Double) -> (Double, Double) {
    // Work on a 100 Hz low-passed signal decimated 4× (plenty for kicks, 4× faster).
    let dec = 4
    let low = Biquad.lowpass(100, sampleRate: sampleRate).applyZeroPhase(mono)
    var lowAbs = [Float](repeating: 0, count: low.count / dec)
    for i in 0..<lowAbs.count { lowAbs[i] = abs(low[i * dec]) }
    let sr = sampleRate / Double(dec)
    let per = 60 / bpm * sr
    let env = movingAverage(lowAbs, max(1, 96 / dec))
    var rise = [Float](repeating: 0, count: env.count)
    for i in 1..<env.count { rise[i] = max(env[i] - env[i - 1], 0) }
    var peaks = findPeaks(rise, height: percentile(rise, 99.5), distance: Int(per * 0.6))
    peaks = refineOnsets(lowAbs, peaks, sampleRate: sr)
    guard peaks.count >= 8 else { return (0, 0) }
    var re = 0.0, im = 0.0
    for p in peaks {
        let a = 2 * Double.pi * Double(p) / per
        re += cos(a); im += sin(a)
    }
    re /= Double(peaks.count); im /= Double(peaks.count)
    let phase = (atan2(im, re) / (2 * .pi)).truncatingRemainder(dividingBy: 1)
    let ph = phase < 0 ? phase + 1 : phase
    let confidence = (re * re + im * im).squareRoot()
    let k = ((Double(peaks[0]) - ph * per) / per).rounded()
    let first = max(ph * per + k * per, ph * per)
    return (first * Double(dec), confidence)
}

/// Move each detected kick back from its steepest rise to where it starts: the
/// last point before the kick's peak where the 5 ms RMS is under 30% of it.
func refineOnsets(_ low: [Float], _ peaks: [Int], sampleRate: Double) -> [Int] {
    let win = max(1, Int(0.005 * sampleRate))
    var sq = [Float](repeating: 0, count: low.count)
    for i in 0..<low.count { sq[i] = low[i] * low[i] }
    let rms = movingAverage(sq, win).map { $0.squareRoot() }
    let back = Int(0.03 * sampleRate), fwd = Int(0.04 * sampleRate)
    return peaks.map { p in
        let a = max(p - back, 0), b = min(p + fwd, rms.count)
        guard b > a else { return p }
        var top = a
        for i in a..<b where rms[i] > rms[top] { top = i }
        var onset = a
        var i = top - 1
        while i >= a {
            if rms[i] < 0.3 * rms[top] { onset = i + 1; break }
            i -= 1
        }
        return onset
    }
}

func barEnergy(_ mono: [Float], sampleRate: Double, firstBeat: Double, bpm: Double) -> [Float] {
    let lp = Biquad.lowpass(150, sampleRate: sampleRate).apply(mono)
    let bar = 4 * 60 / bpm * sampleRate
    let n = Int((Double(mono.count) - firstBeat) / bar)
    guard n > 0 else { return [] }
    var energy = [Float](repeating: 0, count: n)
    for b in 0..<n {
        let s = Int(firstBeat + Double(b) * bar), e = min(Int(firstBeat + Double(b + 1) * bar), lp.count)
        var acc = 0.0
        for i in s..<e { acc += Double(lp[i] * lp[i]) }
        energy[b] = Float((acc / Double(max(e - s, 1))).squareRoot())
    }
    let top = energy.max() ?? 1
    return top > 0 ? energy.map { $0 / top } : energy
}

func waveformSummary(_ audio: DecodedAudio) -> WaveformSummary {
    let mono = audio.mono
    let sr = audio.sampleRate
    let low = Biquad.lowpass(200, sampleRate: sr).apply(mono)
    let high = Biquad.highpass(2500, sampleRate: sr).apply(mono)
    let n = mono.count / WaveformSummary.bucketFrames
    var peak = [Float](repeating: 0, count: n), l = peak, m = peak, h = peak
    for b in 0..<n {
        var pk: Float = 0, sl = 0.0, sm = 0.0, sh = 0.0
        for i in (b * WaveformSummary.bucketFrames)..<((b + 1) * WaveformSummary.bucketFrames) {
            pk = max(pk, abs(mono[i]))
            let mi = mono[i] - low[i] - high[i]
            sl += Double(low[i] * low[i]); sm += Double(mi * mi); sh += Double(high[i] * high[i])
        }
        let k = Double(WaveformSummary.bucketFrames)
        peak[b] = pk
        l[b] = Float((sl / k).squareRoot()); m[b] = Float((sm / k).squareRoot()); h[b] = Float((sh / k).squareRoot())
    }
    func quantise(_ x: [Float]) -> [UInt8] {
        let top = max(x.max() ?? 1, 1e-9)
        return x.map { UInt8(min(255, ($0 / top) * 255)) }
    }
    return WaveformSummary(peak: quantise(peak), low: quantise(l), mid: quantise(m), high: quantise(h))
}

// MARK: - Entry point

/// Full analysis of one decoded file (key, BPM, beat grid, bar energy, waveform).
public func analyse(_ audio: DecodedAudio) -> (TrackAnalysis, WaveformSummary) {
    let mono = audio.mono
    let sr = audio.sampleRate
    let key = detectKey(mono, sampleRate: sr)
    let raw = detectRawBeats(mono, sampleRate: sr)
    let grid = BeatUtils.constantGrid(raw, sampleRate: sr)
    var analysis = TrackAnalysis(sampleRate: sr, frames: audio.frames, key: key,
                                 bpm: grid?.bpm, mixxxFirstBeat: grid?.firstBeat,
                                 firstBeat: nil, beatConfidence: 0, barEnergy: [],
                                 loudness: integratedLoudness(audio))
    if let bpm = grid?.bpm {
        let (kick, confidence) = kickPhase(mono, sampleRate: sr, bpm: bpm)
        let (first, structure) = analyseStructure(mono, sampleRate: sr,
                                                  beatAnchor: confidence > 0 ? kick : (grid?.firstBeat ?? 0), bpm: bpm)
        analysis.firstBeat = first
        analysis.structure = structure
        analysis.beatConfidence = confidence
        analysis.barEnergy = barEnergy(mono, sampleRate: sr,
                                       firstBeat: analysis.firstBeat ?? 0, bpm: bpm)
    }
    return (analysis, waveformSummary(audio))
}
