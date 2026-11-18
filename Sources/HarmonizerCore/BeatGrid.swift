import Foundation

/// Port of Mixxx 2.5 src/track/beatutils.cpp: turn raw (jittery) detector beats
/// into a constant BPM, rounded the way Mixxx rounds, plus Mixxx's first beat.
enum BeatUtils {
    static let maxSecsPhaseError = 0.025
    static let maxSecsPhaseErrorSum = 0.1
    static let maxOutliersCount = 1
    static let minRegionBeatCount = 16

    struct ConstRegion {
        var firstBeat: Double
        var beatLength: Double
    }

    static func retrieveConstRegions(_ beats: [Double], sampleRate: Double) -> [ConstRegion] {
        guard beats.count >= 2 else { return [] }
        let maxPhaseError = maxSecsPhaseError * sampleRate
        let maxPhaseErrorSum = maxSecsPhaseErrorSum * sampleRate
        var left = 0
        var right = beats.count - 1
        var regions: [ConstRegion] = []
        while left < beats.count - 1 {
            let mean = (beats[right] - beats[left]) / Double(right - left)
            var outliers = 0
            var ironed = beats[left]
            var errorSum = 0.0
            var i = left + 1
            while i <= right {
                ironed += mean
                let err = ironed - beats[i]
                errorSum += err
                if abs(err) > maxPhaseError {
                    outliers += 1
                    if outliers > maxOutliersCount || i == left + 1 { break }
                }
                if abs(errorSum) > maxPhaseErrorSum { break }
                i += 1
            }
            if i > right {
                var borderError = 0.0
                if right > left + 2 {
                    let firstLen = beats[left + 1] - beats[left]
                    let lastLen = beats[right] - beats[right - 1]
                    borderError = abs(firstLen + lastLen - 2 * mean)
                }
                if borderError < maxPhaseError / 2 {
                    regions.append(ConstRegion(firstBeat: beats[left], beatLength: mean))
                    left = right
                    right = beats.count - 1
                    continue
                }
            }
            right -= 1
        }
        regions.append(ConstRegion(firstBeat: beats[beats.count - 1], beatLength: 0))
        return regions
    }

    /// Returns (bpm, firstBeat) or nil when no tempo can be inferred.
    static func makeConstBpm(_ regions: [ConstRegion], sampleRate: Double) -> (Double, Double)? {
        guard regions.count >= 2 else { return nil }
        var mid = 0
        var longestLen = 0.0
        var longestBeatLen = 0.0
        for i in 0..<(regions.count - 1) {
            let len = regions[i + 1].firstBeat - regions[i].firstBeat
            if len > longestLen {
                longestLen = len
                longestBeatLen = regions[i].beatLength
                mid = i
            }
        }
        guard longestLen > 0 else { return nil }
        let err = maxSecsPhaseError * sampleRate
        var longestBeats = Int(longestLen / longestBeatLen + 0.5)
        var lenMin = longestBeatLen - err / Double(longestBeats)
        var lenMax = longestBeatLen + err / Double(longestBeats)
        var start = mid

        for i in 0..<mid {
            let len = regions[i + 1].firstBeat - regions[i].firstBeat
            let nb = Int(len / regions[i].beatLength + 0.5)
            if nb < minRegionBeatCount { continue }
            let thisMin = regions[i].beatLength - err / Double(nb)
            let thisMax = regions[i].beatLength + err / Double(nb)
            guard longestBeatLen > thisMin && longestBeatLen < thisMax else { continue }
            let newLen = regions[mid + 1].firstBeat - regions[i].firstBeat
            let bMin = max(lenMin, thisMin)
            let bMax = min(lenMax, thisMax)
            let maxN = Int((newLen / bMin).rounded())
            let minN = Int((newLen / bMax).rounded())
            if minN != maxN { continue }
            let newBeatLen = newLen / Double(minN)
            if newBeatLen > lenMin && newBeatLen < lenMax {
                longestLen = newLen
                longestBeatLen = newBeatLen
                longestBeats = minN
                lenMin = longestBeatLen - err / Double(longestBeats)
                lenMax = longestBeatLen + err / Double(longestBeats)
                start = i
                break
            }
        }

        var i = regions.count - 2
        while i > mid {
            defer { i -= 1 }
            let len = regions[i + 1].firstBeat - regions[i].firstBeat
            let nb = Int(len / regions[i].beatLength + 0.5)
            if nb < minRegionBeatCount { continue }
            let thisMin = regions[i].beatLength - err / Double(nb)
            let thisMax = regions[i].beatLength + err / Double(nb)
            guard longestBeatLen > thisMin && longestBeatLen < thisMax else { continue }
            let newLen = regions[i + 1].firstBeat - regions[start].firstBeat
            let bMin = max(lenMin, thisMin)
            let bMax = min(lenMax, thisMax)
            let maxN = Int((newLen / bMin).rounded())
            let minN = Int((newLen / bMax).rounded())
            if minN != maxN { continue }
            let newBeatLen = newLen / Double(minN)
            if newBeatLen > lenMin && newBeatLen < lenMax {
                longestLen = newLen
                longestBeatLen = newBeatLen
                longestBeats = minN
                break
            }
        }

        lenMin = longestBeatLen - err / Double(longestBeats)
        lenMax = longestBeatLen + err / Double(longestBeats)
        let minRound = 60 * sampleRate / lenMax
        let maxRound = 60 * sampleRate / lenMin
        let center = 60 * sampleRate / longestBeatLen
        let bpm = roundBpmWithinRange(minRound, center, maxRound)
        let roundedLen = 60 * sampleRate / bpm
        let first = fmod(regions[start].firstBeat, roundedLen)
        return (bpm, first)
    }

    static func trySnap(_ minBpm: Double, _ center: Double, _ maxBpm: Double,
                        _ fraction: Double) -> Double? {
        let snap = (center * fraction).rounded() / fraction
        return (snap > minBpm && snap < maxBpm) ? snap : nil
    }

    static func roundBpmWithinRange(_ minBpm: Double, _ center: Double, _ maxBpm: Double) -> Double {
        if let s = trySnap(minBpm, center, maxBpm, 1) { return s }
        if center < 85, let s = trySnap(minBpm, center, maxBpm, 2) { return s }
        if center > 127, let s = trySnap(minBpm, center, maxBpm, 2.0 / 3.0) { return s }
        if let s = trySnap(minBpm, center, maxBpm, 3) { return s }
        if let s = trySnap(minBpm, center, maxBpm, 12) { return s }
        return center
    }

    static func adjustPhase(_ firstBeat: Double, bpm: Double, sampleRate: Double,
                            beats: [Double]) -> Double {
        let beatLen = 60 * sampleRate / bpm
        let startOffset = fmod(firstBeat, beatLen)
        var adjust = 0.0
        var count = 0.0
        for b in beats {
            var off = fmod(b - startOffset, beatLen)
            if off > beatLen / 2 { off -= beatLen }
            if abs(off) < maxSecsPhaseError * sampleRate {
                adjust += off
                count += 1
            }
        }
        return count > 0 ? firstBeat + adjust / count : firstBeat
    }

    /// Mixxx's BeatFactory::makePreferredBeats for a fixed-tempo grid.
    static func constantGrid(_ beats: [Double], sampleRate: Double) -> (bpm: Double, firstBeat: Double)? {
        let regions = retrieveConstRegions(beats, sampleRate: sampleRate)
        guard !regions.isEmpty, let (bpm, first) = makeConstBpm(regions, sampleRate: sampleRate) else {
            return nil
        }
        let adjusted = adjustPhase(first, bpm: bpm, sampleRate: sampleRate, beats: beats)
        return (bpm, adjusted.rounded())
    }
}
