import Foundation

// MARK: - Curves

public enum LaneKind: String, Codable, CaseIterable, Sendable {
    case volume, bass, mid, high, filter, echo
    /// Stem levels (Demucs stems; the track itself when stems aren't ready).
    case drums = "stem_drums", bassline = "stem_bass", melody = "stem_melody", vocals = "stem_vocals"
    /// Effects: a white-noise riser, kick-style ducking, and a reverb send.
    case noise, sidechain, reverb

    public var title: String {
        switch self {
        case .volume: "Volume"
        case .bass: "Bass"
        case .mid: "Mid"
        case .high: "High"
        case .filter: "Filter"
        case .echo: "Echo"
        case .drums: "Drums"
        case .bassline: "Bassline"
        case .melody: "Melody"
        case .vocals: "Vocals"
        case .noise: "Noise"
        case .sidechain: "Side Chain"
        case .reverb: "Reverb"
        }
    }

    public enum Group: String, CaseIterable, Sendable { case mix = "Mix", stems = "Stems", effects = "Effects" }
    public var group: Group {
        switch self {
        case .drums, .bassline, .melody, .vocals: .stems
        case .echo, .noise, .sidechain, .reverb: .effects
        default: .mix
        }
    }

    /// The four stem lanes, in model order (drums, bass, melody, vocals).
    public static let stems: [LaneKind] = [.drums, .bassline, .melody, .vocals]
    public var isStem: Bool { group == .stems }
    /// Effect sends that only rise on the outgoing side by default (incoming stays dry).
    var outgoingOnly: Bool { self == .echo || self == .noise || self == .sidechain || self == .reverb }
    /// Position in `allCases` (curve table index).
    var index: Int { LaneKind.allCases.firstIndex(of: self)! }

    /// The lane's "untouched" level: 1 = full for gains, 0.5 = open filter, 0 = no send/effect.
    public var neutral: Double {
        switch self {
        case .filter: 0.5
        case .echo, .noise, .sidechain, .reverb: 0
        default: 1
        }
    }
}

public enum CurveShape: String, Codable, CaseIterable, Sendable {
    case none, crossfade, fadeIn = "fade_in", fadeOut = "fade_out", swap, manual

    public var title: String {
        switch self {
        case .none: "None"
        case .crossfade: "Crossfade"
        case .fadeIn: "Fade In"
        case .fadeOut: "Fade Out"
        case .swap: "Swap"
        case .manual: "Manual"
        }
    }
}

/// A curve point: x = 0…1 across the transition window, y = 0…1 level, and the
/// bend of the segment to the next point (−1…1; 0 = straight).
public struct Breakpoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var bend: Double

    public init(_ x: Double, _ y: Double, bend: Double = 0) {
        self.x = x
        self.y = y
        self.bend = bend
    }
}

/// Bend → exponent of the segment shape y0 + (y1 − y0)·tᵉ.
@inline(__always) func bendExponent(_ bend: Double) -> Double { pow(2, max(-1, min(1, bend)) * 2) }

/// Value of a breakpoint curve at x (holds the end values outside the points).
public func evaluate(_ points: [Breakpoint], at x: Double) -> Double {
    guard let first = points.first else { return 0 }
    if x <= first.x { return first.y }
    for k in 0..<(points.count - 1) {
        let a = points[k], b = points[k + 1]
        if x <= b.x {
            let span = b.x - a.x
            guard span > 1e-12 else { return b.y }
            let t = (x - a.x) / span
            return a.y + (b.y - a.y) * pow(t, bendExponent(a.bend))
        }
    }
    return points[points.count - 1].y
}

/// Bends approximating equal-power fades (cos/sin of a quarter turn).
private let fadeOutBend = log2(1.77) / 2   // 1 − t^1.77 ≈ cos(πt/2)
private let fadeInBend = -0.5              // t^0.5   ≈ sin(πt/2)

/// Fraction of the window a ramp occupies, by strength (stronger = faster).
func rampWidth(_ strength: Double) -> Double {
    switch strength {
    case ..<0.375: 1.0
    case ..<0.625: 0.75
    case ..<0.875: 0.5
    default: 0.25
    }
}

func swapWidth(_ strength: Double) -> Double {
    switch strength {
    case ..<0.375: 0.25
    case ..<0.625: 0.125
    case ..<0.875: 0.0625
    default: 0
    }
}

public struct LaneSettings: Codable, Equatable, Sendable {
    public var shape: CurveShape
    public var strength: Double
    public var swap: Double
    public var out: [Breakpoint]
    public var inc: [Breakpoint]
    /// Filter: resonance (Q). Echo: delay in beats and feedback.
    public var resonance: Double
    public var echoBeats: Double
    public var feedback: Double

    public init(_ kind: LaneKind, shape: CurveShape, strength: Double = 0.5, swap: Double = 0.5,
                sequential: Bool = false, beats: Int = 64) {
        self.shape = shape
        self.strength = strength
        self.swap = swap
        resonance = 0.9
        echoBeats = 2
        feedback = 0.55
        out = []
        inc = []
        regenerate(kind, sequential: sequential, beats: beats)
    }

    /// Rebuild the breakpoints from shape/strength/swap (not for Manual).
    public mutating func regenerate(_ kind: LaneKind, sequential: Bool, beats: Int) {
        guard shape != .manual else { return }
        let (o, i) = LaneSettings.generate(kind, shape: shape, strength: strength, swap: swap,
                                           sequential: sequential, beats: beats)
        out = o
        inc = i
    }

    static func generate(_ kind: LaneKind, shape: CurveShape, strength: Double, swap: Double,
                         sequential: Bool, beats: Int) -> ([Breakpoint], [Breakpoint]) {
        // Levels each side moves between: "on" (neutral) and "off".
        let n = kind.neutral
        let outOff: Double, inOff: Double
        switch kind {
        case .filter: outOff = 1; inOff = 0          // out: high-pass up; in: low-pass opening
        case _ where kind.outgoingOnly: outOff = 1; inOff = 0   // send/effect rises on the outgoing track only
        default: outOff = 0; inOff = 0
        }
        let flat = { (y: Double) in [Breakpoint(0, y), Breakpoint(1, y)] }
        func fade(from a: Double, to b: Double, start: Double, width: Double) -> [Breakpoint] {
            let s = max(0, min(1, start)), e = max(0, min(1, start + width))
            // Returning to neutral = a fade-in (fast start); leaving it = a fade-out (slow start).
            let returning = abs(b - n) < abs(a - n)
            let bend = returning ? fadeInBend : fadeOutBend
            var pts: [Breakpoint] = []
            if s > 0 { pts.append(Breakpoint(0, a)) }
            pts.append(Breakpoint(s, a, bend: bend))
            pts.append(Breakpoint(e, b))
            if e < 1 { pts.append(Breakpoint(1, b)) }
            return pts
        }
        let w = rampWidth(strength)
        let outStart = sequential ? 1 - w : 0.5 - w / 2
        let inStart = sequential ? 0 : 0.5 - w / 2
        let echoIn = flat(0)
        switch shape {
        case .none, .manual:
            return (flat(n), kind.outgoingOnly ? echoIn : flat(n))
        case .crossfade:
            return (fade(from: n, to: outOff, start: outStart, width: w),
                    kind.outgoingOnly ? echoIn : fade(from: inOff, to: n, start: inStart, width: w))
        case .fadeIn:
            return (flat(n), kind.outgoingOnly ? echoIn : fade(from: inOff, to: n, start: 0, width: w))
        case .fadeOut:
            return (fade(from: n, to: outOff, start: 1 - w, width: w), kind.outgoingOnly ? echoIn : flat(n))
        case .swap:
            var p = swap
            if beats > 0 { p = (p * Double(beats)).rounded() / Double(beats) }
            let sw = swapWidth(strength)
            let s = max(0, p - sw / 2), e = min(1, p + sw / 2)
            func step(_ a: Double, _ b: Double) -> [Breakpoint] {
                [Breakpoint(0, a), Breakpoint(s, a), Breakpoint(max(e, s + 1e-6), b), Breakpoint(1, b)]
            }
            if sequential { return (step(n, outOff), flat(n)) }
            return (step(n, outOff), kind.outgoingOnly ? echoIn : step(inOff, n))
        }
    }
}

// MARK: - Transition spec

public enum TempoMode: String, Codable, CaseIterable, Sendable {
    case full, secondHalf = "second_half"
    public var title: String { self == .full ? "Full" : "Second half" }
}

public struct TransitionSpec: Codable, Equatable, Sendable {
    public var preset: String
    public var bars: Int
    public var sync: Bool
    public var tempo: TempoMode
    public var outNudge: Int   // bars; + = leave later
    public var inNudge: Int    // bars; + = enter later in the incoming track
    public var lanes: [String: LaneSettings]
    public var customised = false
    /// Overrides the project's mix-on mode for this transition.
    public var mixOn: MixOnMode?
    /// Beats of the window before the incoming track starts (nil = 0).
    public var inDelay: Double?
    /// Frozen positions while the transition is locked (nil = not locked).
    public var locked: LockedPlacement?

    public var isLocked: Bool { locked != nil }

    public func lane(_ k: LaneKind) -> LaneSettings? { lanes[k.rawValue] }
    public var activeLanes: [LaneKind] { LaneKind.allCases.filter { lanes[$0.rawValue] != nil } }
    public var beats: Int { bars * 4 }

    /// Regenerate every preset-driven lane (after bars/sync changes).
    public mutating func regenerateLanes() {
        for k in LaneKind.allCases {
            guard var l = lanes[k.rawValue] else { continue }
            l.regenerate(k, sequential: !sync, beats: beats)
            lanes[k.rawValue] = l
        }
    }
}

public let barChoices = [1, 2, 4, 8, 16, 32, 64]

// MARK: - Presets & automatic choice (Resources/transitions.json)

public struct TransitionConfig: Sendable {
    public struct Preset: Sendable {
        public let name: String
        public let bars: Int
        public let sync: Bool
        public let lanes: [LaneKind: (CurveShape, Double, Double)]
    }
    public struct Rule: Sendable {
        let label: String?
        let colour: String?
        let within: String
        let above: String
        let aboveTempo: TempoMode?
    }
    public struct Defaults: Sendable {
        public var inOffsetBars: Int
        public var outOffsetBars: Int
        public var previewLeadBars: Int
        public var tempo: TempoMode
        public var echoFeedback: Double
        public var echoWet: Double
        public var echoTailBars: Int
        public var limiterCeilingDb: Double
    }

    public let presets: [Preset]
    public let rules: [Rule]
    public let defaults: Defaults

    public static let shared = TransitionConfig.load()

    public func preset(_ name: String) -> Preset? { presets.first { $0.name == name } }

    static func load() -> TransitionConfig {
        let url = Bundle.module.url(forResource: "transitions", withExtension: "json")!
        // Bundled with the app; unreadable means a broken build.
        let json = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let order = ["Long Blend", "Smooth Blend", "Filter Blend", "Echo Out", "Quick Cut", "Stem Swap"]
        let rawPresets = json["presets"] as! [String: [String: Any]]
        let names = order.filter { rawPresets[$0] != nil } + rawPresets.keys.filter { !order.contains($0) }.sorted()
        let presets = names.map { name -> Preset in
            let p = rawPresets[name]!
            var lanes: [LaneKind: (CurveShape, Double, Double)] = [:]
            for k in LaneKind.allCases {
                guard let l = p[k.rawValue] as? [String: Any],
                      let shape = CurveShape(rawValue: l["curve"] as? String ?? "") else { continue }
                lanes[k] = (shape, (l["strength"] as? Double) ?? 0.5, (l["swap"] as? Double) ?? 0.5)
            }
            return Preset(name: name, bars: p["bars"] as? Int ?? 16, sync: p["sync"] as? Bool ?? true, lanes: lanes)
        }
        let rules = (json["rules"] as! [[String: Any]]).map {
            Rule(label: $0["label"] as? String, colour: $0["colour"] as? String,
                 within: $0["within"] as! String, above: $0["above"] as! String,
                 aboveTempo: ($0["above_tempo"] as? String).flatMap(TempoMode.init))
        }
        let d = json["defaults"] as! [String: Any]
        return TransitionConfig(
            presets: presets, rules: rules,
            defaults: Defaults(inOffsetBars: d["in_offset_bars"] as? Int ?? 0,
                               outOffsetBars: d["out_offset_bars"] as? Int ?? 0,
                               previewLeadBars: d["preview_lead_bars"] as? Int ?? 8,
                               tempo: TempoMode(rawValue: d["tempo"] as? String ?? "full") ?? .full,
                               echoFeedback: d["echo_feedback"] as? Double ?? 0.55,
                               echoWet: d["echo_wet"] as? Double ?? 0.7,
                               echoTailBars: d["echo_tail_bars"] as? Int ?? 4,
                               limiterCeilingDb: d["limiter_ceiling_db"] as? Double ?? -1))
    }

    /// Spec for a named preset (keeps nudges from `base` if given).
    public func spec(preset name: String, tempo: TempoMode? = nil, base: TransitionSpec? = nil) -> TransitionSpec {
        let p = preset(name) ?? presets[0]
        var lanes: [String: LaneSettings] = [:]
        for (k, v) in p.lanes {
            lanes[k.rawValue] = LaneSettings(k, shape: v.0, strength: v.1, swap: v.2,
                                             sequential: !p.sync, beats: p.bars * 4)
        }
        return TransitionSpec(preset: p.name, bars: p.bars, sync: p.sync,
                              tempo: tempo ?? base?.tempo ?? defaults.tempo,
                              outNudge: base?.outNudge ?? 0, inNudge: base?.inNudge ?? 0, lanes: lanes)
    }

    /// Automatic preset from the harmonic label and BPM gap, with the reason.
    public func autoSpec(_ label: TransitionLabel, bpmGap: Double, tolerance: Double) -> (TransitionSpec, String) {
        let above = abs(bpmGap) > tolerance
        for r in rules {
            if let l = r.label, l != label.label { continue }
            if let c = r.colour, c != label.colour.rawValue { continue }
            let name = above ? r.above : r.within
            let tempo = above ? r.aboveTempo : nil
            var reason = "\(label.label) + " + String(format: "%.1f", abs(bpmGap))
                + " BPM gap (\(above ? "above" : "within") tolerance) → \(name)"
            if let tempo { reason += ", tempo \(tempo.title.lowercased())" }
            return (spec(preset: name, tempo: tempo), reason)
        }
        return (spec(preset: "Echo Out"), "\(label.label): no rule matched → Echo Out")
    }
}

// MARK: - Tempo glide

public enum TempoGlide {
    /// Output frame of each beat boundary while tempo glides from `from` to `to`.
    public static func beatTargets(from a: Double, to b: Double, beats: Int, mode: TempoMode,
                                   sampleRate: Double) -> [Double] {
        var t = [Double](repeating: 0, count: beats + 1)
        let half = beats / 2
        for k in 0..<beats {
            let bpm: Double
            if mode == .secondHalf {
                bpm = k < half ? a : a + (b - a) * (Double(k - half) + 0.5) / Double(max(beats - half, 1))
            } else {
                bpm = a + (b - a) * (Double(k) + 0.5) / Double(beats)
            }
            t[k + 1] = t[k] + 60 / bpm * sampleRate
        }
        return t
    }
}
