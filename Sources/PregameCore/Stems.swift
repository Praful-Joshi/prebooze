import Accelerate
import COnnx
import Foundation

/// The four stems Demucs (htdemucs) separates, in model order.
public enum StemKind: Int, CaseIterable, Codable, Sendable {
    case drums, bass, melody, vocals

    public var title: String {
        switch self {
        case .drums: "Drums"
        case .bass: "Bass"
        case .melody: "Melody"
        case .vocals: "Vocals"
        }
    }
    /// File name inside a stem cache folder.
    public var fileName: String { ["drums", "bass", "melody", "vocals"][rawValue] }
}

public enum StemError: Error, LocalizedError {
    case modelMissing, engine(String)
    public var errorDescription: String? {
        switch self {
        case .modelMissing: "The stem separation model isn't installed (Models/htdemucs.onnx)."
        case let .engine(why): "Stem separation failed: \(why)"
        }
    }
}

/// Demucs v4 (htdemucs) source separation: the network runs in ONNX Runtime
/// (Core ML when available); its STFT/iSTFT, segmentation and overlap-add
/// are done here, exactly as demucs.apply_model does (shifts = 0,
/// overlap = 0.25). Verified against PyTorch Demucs (80–95 dB agreement).
public final class StemSeparator: @unchecked Sendable {
    public static let sampleRate = 44100.0
    static let nfft = 4096, hop = 1024
    static let segment = Int(HZ_DEMUCS_SEGMENT), freqs = Int(HZ_DEMUCS_FREQS), frames = Int(HZ_DEMUCS_FRAMES)
    static let sources = Int(HZ_DEMUCS_SOURCES)

    private let handle: OpaquePointer
    private let lock = NSLock()
    private let fft: STFT

    /// Where the model lives: next to the app's resources, or in the package
    /// (`Models/`) when running from the source tree / tests.
    public static func defaultModelURL() -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Models/htdemucs.onnx"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Models/htdemucs.onnx"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Core ML compilation cache (the first load compiles for ~40 s).
    public static var coreMLCacheURL: URL {
        DataFolders.caches.appendingPathComponent("CoreML", isDirectory: true)
    }

    public init(model: URL? = nil, useCoreML: Bool = true) throws {
        guard let url = model ?? StemSeparator.defaultModelURL() else { throw StemError.modelMissing }
        let cache = StemSeparator.coreMLCacheURL
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        guard let h = hz_demucs_open(url.path, useCoreML ? cache.path : nil, useCoreML ? 1 : 0) else {
            throw StemError.engine(String(cString: hz_demucs_last_error()))
        }
        handle = h
        fft = STFT(n: StemSeparator.nfft)
    }

    deinit { hz_demucs_close(handle) }

    /// Separate stereo audio at 44.1 kHz into the four stems (same length).
    /// `progress` gets 0…1 after each segment; return false to cancel.
    public func separate(left: [Float], right: [Float],
                         progress: ((Double) -> Bool)? = nil) throws -> [[[Float]]] {
        let n = left.count
        let seg = StemSeparator.segment, src = StemSeparator.sources
        // Normalise by the mono mix's mean/std, undone at the end.
        var mean = 0.0, sq = 0.0
        for i in 0..<n { let m = Double(left[i] + right[i]) / 2; mean += m; sq += m * m }
        mean /= Double(max(n, 1))
        let std = max((sq / Double(max(n, 1)) - mean * mean).squareRoot() * (Double(n) / Double(max(n - 1, 1))).squareRoot(), 1e-8)
        let mix = [left, right].map { ch in ch.map { Float((Double($0) - mean) / std) } }

        // Triangle weights for the overlap-add (linear transitions at 25 % overlap).
        var weight = [Float](repeating: 0, count: seg)
        for i in 0..<(seg / 2) { weight[i] = Float(i + 1) }
        for i in (seg / 2)..<seg { weight[i] = Float(seg - i) }
        let top = weight.max() ?? 1
        vDSP.divide(weight, top, result: &weight)

        var out = [[[Float]]](repeating: [[Float]](repeating: [Float](repeating: 0, count: n), count: 2), count: src)
        var wsum = [Float](repeating: 0, count: n)
        let stride = Int(0.75 * Double(seg))
        let offsets = Array(Swift.stride(from: 0, to: n, by: stride))
        var chunk = [[Float]](repeating: [Float](repeating: 0, count: seg), count: 2)
        for (k, off) in offsets.enumerated() {
            let len = min(seg, n - off), delta = seg - len
            let start = off - delta / 2
            for c in 0..<2 {
                for i in 0..<seg {
                    let j = start + i
                    chunk[c][i] = j >= 0 && j < n ? mix[c][j] : 0
                }
            }
            let o = try runSegment(chunk)            // [source][channel][seg]
            let trim = delta / 2
            for s in 0..<src {
                for c in 0..<2 {
                    o[s][c].withUnsafeBufferPointer { p in
                        out[s][c].withUnsafeMutableBufferPointer { q in
                            for i in 0..<len { q[off + i] += weight[i] * p[trim + i] }
                        }
                    }
                }
            }
            for i in 0..<len { wsum[off + i] += weight[i] }
            if let progress, !progress(Double(k + 1) / Double(offsets.count)) { throw CancellationError() }
        }
        for s in 0..<src {
            for c in 0..<2 {
                for i in 0..<n { out[s][c][i] = Float(Double(out[s][c][i] / wsum[i]) * std + mean) }
            }
        }
        return out
    }

    /// One model call: spectrogram in, (spectrogram + waveform) out, back to audio.
    func runSegment(_ chunk: [[Float]]) throws -> [[[Float]]] {
        let seg = StemSeparator.segment, F = StemSeparator.freqs, T = StemSeparator.frames
        let src = StemSeparator.sources
        // Input spectrogram: complex as channels [L.re, L.im, R.re, R.im] × F × T.
        var mag = [Float](repeating: 0, count: 4 * F * T)
        for c in 0..<2 {
            let (re, im) = fft.spec(chunk[c], frames: T, freqs: F)
            mag.replaceSubrange((2 * c * F * T)..<((2 * c + 1) * F * T), with: re)
            mag.replaceSubrange(((2 * c + 1) * F * T)..<((2 * c + 2) * F * T), with: im)
        }
        let mixIn = chunk[0] + chunk[1]
        var outSpec = [Float](repeating: 0, count: src * 4 * F * T)
        var outTime = [Float](repeating: 0, count: src * 2 * seg)
        let rc: Int32 = lock.withLock {
            mixIn.withUnsafeBufferPointer { m in
                mag.withUnsafeBufferPointer { g in
                    outSpec.withUnsafeMutableBufferPointer { os in
                        outTime.withUnsafeMutableBufferPointer { ot in
                            hz_demucs_run(handle, m.baseAddress, g.baseAddress, os.baseAddress, ot.baseAddress)
                        }
                    }
                }
            }
        }
        guard rc == 0 else { throw StemError.engine(String(cString: hz_demucs_last_error())) }
        var result = [[[Float]]]()
        for s in 0..<src {
            var chans = [[Float]]()
            for c in 0..<2 {
                let base = (s * 4 + 2 * c) * F * T
                let re = Array(outSpec[base..<(base + F * T)])
                let im = Array(outSpec[(base + F * T)..<(base + 2 * F * T)])
                var y = fft.ispec(re: re, im: im, frames: T, freqs: F, length: seg)
                let tb = (s * 2 + c) * seg
                outTime.withUnsafeBufferPointer { p in
                    vDSP.add(y, UnsafeBufferPointer(rebasing: p[tb..<(tb + seg)]), result: &y)
                }
                chans.append(y)
            }
            result.append(chans)
        }
        return result
    }
}

/// STFT/iSTFT matching torch.stft/istft(n_fft 4096, hop 1024, periodic Hann,
/// normalized, center, reflect) as Demucs' standalone_spec/ispec use them.
struct STFT {
    let n: Int
    let hop: Int
    let window: [Float]
    private let forward: vDSP.DiscreteFourierTransform<Float>
    private let inverse: vDSP.DiscreteFourierTransform<Float>

    init(n: Int) {
        self.n = n
        hop = n / 4
        window = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
        forward = try! vDSP.DiscreteFourierTransform(previous: nil, count: n, direction: .forward,
                                                     transformType: .complexComplex, ofType: Float.self)
        inverse = try! vDSP.DiscreteFourierTransform(previous: nil, count: n, direction: .inverse,
                                                     transformType: .complexComplex, ofType: Float.self)
    }

    /// standalone_spec: frame k covers samples [k·hop − 1.5·hop, … + n) with
    /// reflection at the edges. Returns (re, im) as freqs × frames (row-major by freq).
    func spec(_ x: [Float], frames T: Int, freqs F: Int) -> ([Float], [Float]) {
        let len = x.count, scale = 1 / Float(n).squareRoot()
        var re = [Float](repeating: 0, count: F * T), im = re
        var fr = [Float](repeating: 0, count: n), fi = [Float](repeating: 0, count: n)
        var or = [Float](repeating: 0, count: n), oi = [Float](repeating: 0, count: n)
        func at(_ i: Int) -> Float {
            if i < 0 { return x[min(-i, len - 1)] }
            if i >= len { return x[max(2 * len - 2 - i, 0)] }
            return x[i]
        }
        for k in 0..<T {
            let s0 = k * hop - hop / 2 * 3
            for i in 0..<n { fr[i] = at(s0 + i) * window[i] }
            forward.transform(inputReal: fr, inputImaginary: fi, outputReal: &or, outputImaginary: &oi)
            for f in 0..<F {
                re[f * T + k] = or[f] * scale
                im[f * T + k] = oi[f] * scale
            }
        }
        return (re, im)
    }

    /// standalone_ispec: the bins (plus a zero Nyquist bin, plus two empty
    /// frames either side) inverse-transformed and overlap-added with the
    /// torch.istft window-square normalisation, trimmed to `length`.
    func ispec(re: [Float], im: [Float], frames T: Int, freqs F: Int, length: Int) -> [Float] {
        var y = [Float](repeating: 0, count: length)
        var fr = [Float](repeating: 0, count: n), fi = fr, or = fr, oi = fr
        let shift = 2 * hop + hop / 2 * 3    // frame k (of T) starts at k·hop − shift + 2·hop
        let scale = Float(n).squareRoot() / Float(n)
        for k in 0..<T {
            // Hermitian spectrum → real frame (bin F = Nyquist is zero).
            fr[0] = re[k]; fi[0] = 0
            for f in 1..<F {
                fr[f] = re[f * T + k]; fi[f] = im[f * T + k]
                fr[n - f] = fr[f]; fi[n - f] = -fi[f]
            }
            fr[F] = 0; fi[F] = 0
            inverse.transform(inputReal: fr, inputImaginary: fi, outputReal: &or, outputImaginary: &oi)
            let start = (k + 2) * hop - shift
            for i in 0..<n {
                let j = start + i
                if j >= 0 && j < length { y[j] += or[i] * scale * window[i] }
            }
        }
        // Window-square sum over all T + 4 frames (the padded empty ones count too).
        var wsum = [Float](repeating: 0, count: length)
        for k in 0..<(T + 4) {
            let start = k * hop - shift
            for i in 0..<n {
                let j = start + i
                if j >= 0 && j < length { wsum[j] += window[i] * window[i] }
            }
        }
        for j in 0..<length where wsum[j] > 1e-11 { y[j] /= wsum[j] }
        return y
    }
}
