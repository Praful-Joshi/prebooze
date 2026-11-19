import CRubberBand
import Foundation

/// Beat-accurate, pitch-preserving time stretching with Rubber Band (offline
/// mode + key-frame map), set up like the CLI's `-c 6`: compound detector,
/// crisp transients, independent phase, short window. Measured in the old app:
/// beats of two stretched tracks stay within ~4 ms of each other.
public enum Stretcher {
    static let options = Int32(
        RubberBandOptionProcessOffline.rawValue | RubberBandOptionTransientsCrisp.rawValue
            | RubberBandOptionDetectorCompound.rawValue | RubberBandOptionPhaseIndependent.rawValue
            | RubberBandOptionWindowShort.rawValue | RubberBandOptionThreadingNever.rawValue
            | RubberBandOptionEngineFaster.rawValue)

    /// Stretch `channels` so each sourcePoints[k] lands on targetPoints[k]
    /// (optionally also shifting pitch by `pitchScale`).
    /// Both lists start at 0 and end at the segment boundaries; the output has
    /// exactly targetPoints.last frames.
    public static func stretch(_ channels: [[Float]], sampleRate: Double,
                               sourcePoints: [Double], targetPoints: [Double],
                               pitchScale: Double = 1) -> [[Float]] {
        precondition(sourcePoints.count == targetPoints.count && sourcePoints.count >= 2)
        precondition(pitchScale == 1 || sourcePoints.count == 2, "key-frame maps don't combine with pitch shifts")
        let n = channels[0].count
        let chCount = channels.count
        var src = sourcePoints.map { Int($0.rounded()) }
        let dst = targetPoints.map { Int($0.rounded()) }
        src[src.count - 1] = n
        let outLen = max(dst[dst.count - 1], 0)
        guard n > 0, outLen > 0 else {
            return channels.map { _ in [Float](repeating: 0, count: outLen) }
        }
        if src == dst && pitchScale == 1 { return channels }

        let block = 4096
        // Owned C buffers: input copy, retrieval scratch, and pointer tables.
        let input = channels.map { ch -> UnsafeMutablePointer<Float> in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
            ch.withUnsafeBufferPointer { p.initialize(from: $0.baseAddress!, count: n) }
            return p
        }
        let scratch = (0..<chCount).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: block) }
        let inPtrs = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: chCount)
        let outPtrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: chCount)
        defer {
            input.forEach { $0.deallocate() }
            scratch.forEach { $0.deallocate() }
            inPtrs.deallocate()
            outPtrs.deallocate()
        }
        for c in 0..<chCount { outPtrs[c] = scratch[c] }

        let rb = rubberband_new(UInt32(sampleRate), UInt32(chCount), options,
                                Double(outLen) / Double(n), pitchScale)!
        defer { rubberband_delete(rb) }
        rubberband_set_expected_input_duration(rb, UInt32(n))
        rubberband_set_max_process_size(rb, UInt32(block))

        var out = (0..<chCount).map { _ -> [Float] in
            var a = [Float]()
            a.reserveCapacity(outLen + block)
            return a
        }
        var toDrop = Int(rubberband_get_start_delay(rb))

        func drain() {
            while true {
                let avail = Int(rubberband_available(rb))
                if avail <= 0 { return }
                let k = min(avail, block)
                _ = rubberband_retrieve(rb, outPtrs, UInt32(k))
                var start = 0
                if toDrop > 0 {
                    start = min(toDrop, k)
                    toDrop -= start
                }
                if start < k {
                    for c in 0..<chCount {
                        out[c].append(contentsOf: UnsafeBufferPointer(start: scratch[c] + start, count: k - start))
                    }
                }
            }
        }

        func feed(study: Bool) {
            var pos = 0
            while pos < n {
                let count = min(block, n - pos)
                let final: Int32 = pos + count >= n ? 1 : 0
                for c in 0..<chCount { inPtrs[c] = UnsafePointer(input[c] + pos) }
                if study {
                    rubberband_study(rb, inPtrs, UInt32(count), final)
                } else {
                    rubberband_process(rb, inPtrs, UInt32(count), final)
                    drain()
                }
                pos += count
            }
        }

        feed(study: true)
        // R2 applies the map before resampling for pitch, so a map with a pitch
        // shift would skew; a two-point map adds nothing anyway.
        if src.count > 2 {
            var from = src.map { UInt32($0) }, to = dst.map { UInt32($0) }
            rubberband_set_key_frame_map(rb, UInt32(from.count), &from, &to)
        }
        feed(study: false)
        drain()
        return out.map { $0.count >= outLen ? Array($0[0..<outLen])
                                            : $0 + [Float](repeating: 0, count: outLen - $0.count) }
    }
}
