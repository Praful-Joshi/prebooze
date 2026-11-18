import Foundation

/// What the user corrected or added for one audio file (kept in the analysis
/// cache by content hash, so it follows the file into every project).
public struct TrackEdits: Codable, Equatable, Sendable {
    /// Corrected sections (nil = use the detected ones).
    public var structure: TrackStructure?
    /// Hot cues 1–8: seconds into the file.
    public var cues: [Double?] = Array(repeating: nil, count: 8)
    /// Bar 1 moved by this many beats from the detected downbeat.
    public var downbeatShift = 0

    public init() {}

    enum CodingKeys: String, CodingKey { case structure, cues, downbeatShift }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        structure = try c.decodeIfPresent(TrackStructure.self, forKey: .structure)
        let saved = try c.decodeIfPresent([Double?].self, forKey: .cues) ?? []
        cues = (0..<8).map { $0 < saved.count ? saved[$0] : nil }
        downbeatShift = try c.decodeIfPresent(Int.self, forKey: .downbeatShift) ?? 0
    }
}

/// How a track's audio is altered before mixing: pitch shift, then loops
/// (regions played extra times). Frames are the file's own (native rate).
public struct AudioVariant: Hashable, Sendable {
    public struct Insert: Hashable, Sendable {
        public var start: Double
        public var length: Double
        public var repeats: Int
        public var end: Double { start + length }
        public var extra: Double { length * Double(repeats) }
    }

    public var semitones = 0
    /// Sorted, non-overlapping.
    public var loops: [Insert] = []

    public init(semitones: Int = 0, loops: [Insert] = []) {
        self.semitones = semitones
        self.loops = loops
    }

    public var isIdentity: Bool { semitones == 0 && loops.isEmpty }

    /// Appended to the file path to key decoded audio.
    public var signature: String {
        isIdentity ? "" : "#\(semitones)" + loops.map { String(format: "|%.1f+%.1fx%d", $0.start, $0.length, $0.repeats) }.joined()
    }

    public var extraFrames: Double { loops.reduce(0) { $0 + $1.extra } }

    /// A position in the file → the same sound's first play in the varied audio.
    public func virtualFrame(_ src: Double) -> Double {
        src + loops.filter { $0.end <= src }.reduce(0) { $0 + $1.extra }
    }

    /// A position in the varied audio → where that sound is in the file
    /// (repeats map back into their region).
    public func sourceFrame(ofVirtual v: Double) -> Double {
        var shift = 0.0
        for loop in loops {
            let start = loop.start + shift
            if v < start + loop.length { break }
            let played = loop.length * Double(loop.repeats + 1)
            if v < start + played {
                return loop.start + (v - start).truncatingRemainder(dividingBy: loop.length)
            }
            shift += loop.extra
        }
        return v - shift
    }

    /// Apply to decoded audio (any rate; `nativeRate` is the rate the frames refer to).
    public func apply(to audio: DecodedAudio, nativeRate: Double) -> DecodedAudio {
        guard !isIdentity else { return audio }
        var l = audio.left, r = audio.right
        if semitones != 0 {
            let shifted = Stretcher.stretch([l, r], sampleRate: audio.sampleRate,
                                            sourcePoints: [0, Double(l.count)], targetPoints: [0, Double(l.count)],
                                            pitchScale: pow(2, Double(semitones) / 12))
            l = shifted[0]; r = shifted[1]
        }
        guard !loops.isEmpty else { return DecodedAudio(sampleRate: audio.sampleRate, left: l, right: r) }
        let k = audio.sampleRate / nativeRate
        let xf = Int(0.005 * audio.sampleRate)
        var outL: [Float] = [], outR: [Float] = []
        let total = l.count + Int((extraFrames * k).rounded()) + 1
        outL.reserveCapacity(total); outR.reserveCapacity(total)
        var src = 0
        var virtualPos = 0.0     // exact virtual frame (rate-scaled) of `src`, to keep the grid exact
        for loop in loops {
            let s = Int((loop.start * k).rounded()), e = min(Int((loop.end * k).rounded()), l.count)
            guard s >= src, e > s else { continue }
            // Up to the end of the region (first play).
            outL += l[src..<e]; outR += r[src..<e]
            virtualPos += Double(e - src)
            for _ in 0..<loop.repeats {
                // Each repeat is exactly length·k frames long overall (rounded cumulatively).
                let target = Int((virtualPos + loop.length * k).rounded())
                let n = target - Int(virtualPos.rounded())
                let seam = outL.count
                for i in 0..<n {
                    let j = s + i
                    outL.append(j < l.count ? l[j] : 0); outR.append(j < r.count ? r[j] : 0)
                }
                // Crossfade the jump back: fade out what would have followed the region end.
                for i in 0..<min(xf, n) where e + i < l.count {
                    let t = Float(i) / Float(xf)
                    let rise = sin(t * .pi / 2), fall = cos(t * .pi / 2)
                    outL[seam + i] = outL[seam + i] * rise + l[e + i] * fall
                    outR[seam + i] = outR[seam + i] * rise + r[e + i] * fall
                }
                virtualPos += loop.length * k
            }
            src = e
        }
        outL += l[src...]; outR += r[src...]
        return DecodedAudio(sampleRate: audio.sampleRate, left: outL, right: outR)
    }
}

/// Everything mixing needs about one track: its grid and sections as heard in
/// the mix (after bar-1 correction, BPM override and loops), and the audio variant.
public struct TrackMixInfo: Sendable {
    public let track: ProjectTrack
    public let analysis: TrackAnalysis
    public let edits: TrackEdits
    /// The file's grid (native rate), before loops.
    public let baseGrid: TrackGrid
    /// The grid of the audio as mixed (loops included).
    public let grid: TrackGrid
    /// Sections on `baseGrid` (what the user edits) and on `grid`.
    public let baseStructure: TrackStructure?
    public let structure: TrackStructure?
    public let variant: AudioVariant
    /// Looped regions in bars of `grid` (the whole played-out loop).
    public let introLoopBars: Range<Int>?
    public let outroLoopBars: Range<Int>?

    /// Hot cue positions in frames of `grid` (native rate).
    public var cueFrames: [Double?] {
        edits.cues.map { $0.map { variant.virtualFrame($0 * baseGrid.sampleRate) } }
    }
}

extension TrackGrid {
    /// Bar 1 moved by whole beats (kept inside the file).
    func shifted(beats: Int) -> TrackGrid {
        guard beats != 0 else { return self }
        var first = firstBeat + Double(beats) * beatLength
        while first < 0 { first += barLength }
        while first >= barLength { first -= barLength }
        return TrackGrid(frames: frames, sampleRate: sampleRate, firstBeat: first, bpm: bpm, confidence: confidence)
    }
}

extension AnalysisCache {
    /// Mix info for a track, or nil while it lacks analysis.
    public func mixInfo(_ t: ProjectTrack) -> TrackMixInfo? {
        guard let hash = t.contentHash, let a = cached(hash),
              let detected = TrackGrid(a, bpmOverride: t.bpmOverride) else { return nil }
        let e = edits(hash)
        let base = detected.shifted(beats: e.downbeatShift)
        let baseStructure = (e.structure ?? a.structure)?.rebased(to: base)
        var structure = baseStructure
        var inserts: [AudioVariant.Insert] = []
        var introBars: Range<Int>? = nil, outroBars: Range<Int>? = nil
        var extraBars = 0, introRegion = 0
        if let loop = t.introLoop, loop.repeats > 0 {
            let bars = min(loop.bars, base.bars)
            if bars > 0 {
                introRegion = bars
                inserts.append(.init(start: base.barFrame(0), length: Double(bars) * base.barLength, repeats: loop.repeats))
                structure = structure?.inserting(bars: bars * loop.repeats, at: 0)
                introBars = 0..<(bars * (loop.repeats + 1))
                extraBars += bars * loop.repeats
            }
        }
        if let loop = t.outroLoop, loop.repeats > 0 {
            let bars = min(loop.bars, base.bars)
            let exit = baseStructure?.exitBar ?? max(0, base.bars - 16)
            let start = max(min(exit, base.bars - bars), introRegion)
            if bars > 0, start + bars <= base.bars {
                inserts.append(.init(start: base.barFrame(Double(start)), length: Double(bars) * base.barLength,
                                     repeats: loop.repeats))
                structure = structure?.inserting(bars: bars * loop.repeats, at: start + extraBars)
                outroBars = (start + extraBars)..<(start + extraBars + bars * (loop.repeats + 1))
                extraBars += bars * loop.repeats
            }
        }
        let variant = AudioVariant(semitones: t.keyShift, loops: inserts)
        let grid = TrackGrid(frames: base.frames + Int((Double(extraBars) * base.barLength).rounded()),
                             sampleRate: base.sampleRate, firstBeat: base.firstBeat, bpm: base.bpm,
                             confidence: base.confidence)
        if var s = structure { s.bars = grid.bars; structure = s }
        return TrackMixInfo(track: t, analysis: a, edits: e, baseGrid: base, grid: grid,
                            baseStructure: baseStructure, structure: structure,
                            variant: variant, introLoopBars: introBars, outroLoopBars: outroBars)
    }
}
