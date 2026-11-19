import Foundation

/// A track's constant beat grid in its own frames.
public struct TrackGrid: Sendable {
    public let frames: Int
    public let sampleRate: Double
    public let firstBeat: Double
    public let bpm: Double
    public let confidence: Double

    public init(frames: Int, sampleRate: Double, firstBeat: Double, bpm: Double, confidence: Double = 1) {
        self.frames = frames
        self.sampleRate = sampleRate
        self.firstBeat = firstBeat
        self.bpm = bpm
        self.confidence = confidence
    }

    public init?(_ a: TrackAnalysis, bpmOverride: Double? = nil) {
        guard let bpm = bpmOverride ?? a.bpm, let first = a.firstBeat ?? a.mixxxFirstBeat else { return nil }
        self.init(frames: a.frames, sampleRate: a.sampleRate, firstBeat: first, bpm: bpm,
                  confidence: a.beatConfidence)
    }

    public var beatLength: Double { 60 / bpm * sampleRate }
    public var barLength: Double { 4 * beatLength }
    public func barFrame(_ bar: Double) -> Double { firstBeat + bar * barLength }
    /// Complete bars from bar 1 (index 0) to the end.
    public var bars: Int { max(0, Int((Double(frames) - firstBeat) / barLength)) }
}

/// Where one transition happens on both tracks.
public struct TransitionPlan: Sendable {
    public let index: Int
    public let from: UUID
    public let to: UUID
    public var spec: TransitionSpec
    public var bars: Int            // effective length (may be shortened to fit)
    public var outStartBar: Int
    public var outEndBar: Int
    public var inStartBar: Int
    /// Beats of the window before the incoming track starts (whole beats when synced).
    public var inDelay: Double = 0
    /// The mode actually used (after any fallback).
    public var mode: MixOnMode
    public var warnings: [String]

    public var beats: Int { bars * 4 }
    /// Beats of the incoming track heard inside the window.
    public var inBeats: Int { spec.sync ? beats - Int(inDelay) : beats }
    /// Where the incoming track's part of the window ends, in its beats from bar 1.
    public var inEndBeat: Int { inStartBar * 4 + inBeats }
    /// The bar the incoming track has reached when the window ends (rounded up).
    public var inEndBar: Int { (inEndBeat + 3) / 4 }

    /// The placement to freeze when this transition is locked.
    public var placement: LockedPlacement {
        LockedPlacement(bars: bars, outStartBar: outStartBar, inStartBar: inStartBar, inDelay: inDelay)
    }
}

/// A hand-finished transition's exact positions, kept while it is locked.
public struct LockedPlacement: Codable, Equatable, Sendable {
    public var bars: Int
    public var outStartBar: Int
    public var inStartBar: Int
    public var inDelay: Double
}

/// Where transitions sit on the two tracks.
public enum MixOnMode: String, Codable, CaseIterable, Sendable {
    /// Leave on the last 8-bar step before the end; enter at bar 1.
    case bars
    /// Like bars, but on the detected phrase grid.
    case phrase
    /// Leave at the outro (or last break); enter at the intro's start.
    case introOutro = "intro_outro"
    /// Leave at the outro (or last break); the incoming drop lands as the window ends.
    case structure

    public var title: String {
        switch self {
        case .bars: "Bars"
        case .phrase: "Phrase"
        case .introOutro: "Intro / Outro"
        case .structure: "Song Structure"
        }
    }
}

public struct TransitionDefaults: Codable, Equatable, Sendable {
    public var inOffsetBars: Int
    public var outOffsetBars: Int
    public var previewLeadBars: Int
    public var mixOn: MixOnMode

    /// Below this structure confidence, structure modes fall back to Phrase.
    public static let minStructureConfidence = 0.5

    public init(_ c: TransitionConfig.Defaults = TransitionConfig.shared.defaults) {
        inOffsetBars = c.inOffsetBars
        outOffsetBars = c.outOffsetBars
        previewLeadBars = c.previewLeadBars
        mixOn = .structure
    }

    enum CodingKeys: String, CodingKey { case inOffsetBars, outOffsetBars, previewLeadBars, mixOn }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TransitionDefaults()
        inOffsetBars = try c.decodeIfPresent(Int.self, forKey: .inOffsetBars) ?? d.inOffsetBars
        outOffsetBars = try c.decodeIfPresent(Int.self, forKey: .outOffsetBars) ?? d.outOffsetBars
        previewLeadBars = try c.decodeIfPresent(Int.self, forKey: .previewLeadBars) ?? d.previewLeadBars
        mixOn = try c.decodeIfPresent(MixOnMode.self, forKey: .mixOn) ?? .structure
    }
}

/// Mix points for each transition, by mix-on mode (the spec's own, else the
/// project default), then nudges. `structures` are on the same grids.
public func planTransitions(grids: [TrackGrid], structures: [TrackStructure?]? = nil, ids: [UUID],
                            specs: [TransitionSpec], defaults: TransitionDefaults) -> [TransitionPlan] {
    var plans: [TransitionPlan] = []
    for (t, spec) in specs.enumerated() {
        let out = grids[t], inc = grids[t + 1]
        let so = structures?[t], si = structures?[t + 1]
        var warnings: [String] = []
        var mode = spec.mixOn ?? defaults.mixOn
        if mode == .structure || mode == .introOutro {
            let unclear = [(so, "outgoing"), (si, "incoming")]
                .filter { ($0.0?.confidence ?? 0) < TransitionDefaults.minStructureConfidence }.map(\.1)
            if !unclear.isEmpty {
                warnings.append("Song structure unclear on the \(unclear.joined(separator: " and ")) track: mixed on phrases instead. Check the sections.")
                mode = .phrase
            }
        }
        if let lock = spec.locked {
            plans.append(lockedPlan(lock, index: t, ids: ids, spec: spec, out: out, inc: inc,
                                    ownEntryEnd: plans.last?.inEndBar ?? 0, mode: mode))
            continue
        }
        var bars = spec.bars
        var end: Int, inStart: Int
        switch mode {
        case .bars, .phrase:
            let po = mode == .phrase ? (so?.phraseOffset ?? 0) : 0
            let usable = out.bars - defaults.outOffsetBars
            end = usable - po >= 8 ? po + ((usable - po) / 8) * 8 : usable
            inStart = (mode == .phrase ? (si?.phraseOffset ?? 0) : 0) + defaults.inOffsetBars
        case .introOutro, .structure:
            end = (so?.exitBar ?? max(0, out.bars - bars)) + bars
            if mode == .introOutro {
                inStart = 0
            } else {
                let entry = si?.entryBar ?? bars
                inStart = max(0, entry - bars)
                // Worth a warning only when the drop comes in the first half.
                if entry * 2 < bars {
                    warnings.append("The incoming intro is only \(entry) bars, so its drop lands inside the transition. Shorten the transition or add an intro loop.")
                }
            }
        }
        end = min(max(end + spec.outNudge, 1), out.bars)
        inStart = max(inStart + spec.inNudge, 0)
        // The outgoing window must start after this track's own entry window ends.
        let ownEntryEnd = plans.last?.inEndBar ?? 0
        while bars > 1 && end - bars < ownEntryEnd {
            bars = barChoices.last { $0 < bars } ?? 1
        }
        if end - bars < ownEntryEnd { end = min(ownEntryEnd + bars, out.bars) }
        if bars != spec.bars {
            warnings.append("Shortened to \(bars) bars: the outgoing track is too short for \(spec.bars) bars after its own mix-in.")
        }
        if inStart + bars > inc.bars {
            inStart = max(inc.bars - bars, 0)
            warnings.append("Incoming mix-in moved earlier: the track is too short.")
        }
        for (g, name) in [(out, "outgoing"), (inc, "incoming")] where g.confidence < 0.5 {
            warnings.append(String(format: "Low beat-grid confidence (%.2f) on the %@ track: check alignment by ear.",
                                   g.confidence, name))
        }
        plans.append(TransitionPlan(index: t, from: ids[t], to: ids[t + 1], spec: spec, bars: bars,
                                    outStartBar: end - bars, outEndBar: end, inStartBar: inStart,
                                    inDelay: clampedDelay(spec, beats: bars * 4), mode: mode, warnings: warnings))
    }
    return plans
}

/// Synced windows delay the incoming by whole beats (it must stay on the beat)
/// and keep at least one beat of it; sequential ones can wait any time.
func clampedDelay(_ spec: TransitionSpec, beats: Int) -> Double {
    let d = max(0, spec.inDelay ?? 0)
    return spec.sync ? min(d.rounded(), Double(max(beats - 1, 0))) : min(d, 256)
}

/// A locked transition keeps its frozen positions; if they no longer fit
/// (the track got shorter, its own mix-in moved) it stays put as far as
/// possible and says so instead of moving silently.
func lockedPlan(_ lock: LockedPlacement, index t: Int, ids: [UUID], spec: TransitionSpec, out: TrackGrid,
                inc: TrackGrid, ownEntryEnd: Int, mode: MixOnMode) -> TransitionPlan {
    var problems: [String] = []
    var bars = max(1, lock.bars), outStart = lock.outStartBar, inStart = lock.inStartBar
    if outStart + bars > out.bars {
        problems.append("the outgoing track is now shorter")
        outStart = max(0, out.bars - bars)
        bars = min(bars, out.bars)
    }
    if outStart < ownEntryEnd { problems.append("the outgoing track's own mix-in now ends later") }
    if inStart + bars > inc.bars {
        problems.append("the incoming track is now shorter")
        inStart = max(0, inc.bars - bars)
    }
    var locked = spec
    locked.bars = bars
    locked.inDelay = lock.inDelay
    let warnings = problems.isEmpty ? [] : ["Locked transition no longer fits as saved (" + problems.joined(separator: "; ")
                                            + "). Unlock it to re-place it."]
    return TransitionPlan(index: t, from: ids[t], to: ids[t + 1], spec: spec, bars: bars,
                          outStartBar: outStart, outEndBar: outStart + bars, inStartBar: inStart,
                          inDelay: clampedDelay(locked, beats: bars * 4), mode: mode, warnings: warnings)
}

// MARK: - Loudness

/// Integrated loudness (ITU-R BS.1770 style: K-weighting, 400 ms blocks,
/// absolute −70 LUFS and relative −10 LU gates).
func integratedLoudness(_ audio: DecodedAudio) -> Double? {
    let sr = audio.sampleRate
    let shelf = Biquad.highShelf(1681.97, gainDb: 4, sampleRate: sr)
    let hp = Biquad.highpass(38.13, sampleRate: sr, q: 0.5)
    let l = hp.apply(shelf.apply(audio.left)), r = hp.apply(shelf.apply(audio.right))
    let block = Int(0.4 * sr), hop = Int(0.1 * sr)
    guard l.count >= block else { return nil }
    var powers: [Double] = []
    var start = 0
    while start + block <= l.count {
        var acc = 0.0
        for i in start..<(start + block) { acc += Double(l[i] * l[i] + r[i] * r[i]) }
        powers.append(acc / Double(block))
        start += hop
    }
    func lufs(_ p: Double) -> Double { -0.691 + 10 * log10(max(p, 1e-12)) }
    let absGated = powers.filter { lufs($0) > -70 }
    guard !absGated.isEmpty else { return nil }
    let rel = lufs(absGated.reduce(0, +) / Double(absGated.count)) - 10
    let gated = absGated.filter { lufs($0) > rel }
    guard !gated.isEmpty else { return nil }
    return lufs(gated.reduce(0, +) / Double(gated.count))
}

/// Linear gain per track so all play at the set's median loudness, plus trims.
public func loudnessGains(_ loudness: [Double?], trimsDb: [Double]) -> [Float] {
    let known = loudness.compactMap { $0 }.sorted()
    let median = known.isEmpty ? -14 : known[known.count / 2]
    return zip(loudness, trimsDb).map { l, trim in
        let db = max(-12, min(12, median - (l ?? median))) + trim
        return Float(pow(10, db / 20))
    }
}

extension Biquad {
    static func highShelf(_ freq: Double, gainDb: Double, sampleRate: Double, q: Double = 0.7071067811865476) -> Biquad {
        let a = pow(10, gainDb / 40)
        let w = 2 * Double.pi * freq / sampleRate
        let cw = cos(w), alpha = sin(w) / (2 * q)
        let sq = 2 * a.squareRoot() * alpha
        let a0 = (a + 1) - (a - 1) * cw + sq
        return Biquad(b0: a * ((a + 1) + (a - 1) * cw + sq) / a0,
                      b1: -2 * a * ((a - 1) + (a + 1) * cw) / a0,
                      b2: a * ((a + 1) + (a - 1) * cw - sq) / a0,
                      a1: 2 * ((a - 1) - (a + 1) * cw) / a0,
                      a2: ((a + 1) - (a - 1) * cw - sq) / a0)
    }
}
