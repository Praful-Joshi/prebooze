import Foundation

// MARK: - Config (Resources/config.json)

public struct HarmonicConfig: Codable, Sendable {
    public struct Rule: Codable, Sendable {
        public let label: String
        public let colour: String
        public let letter: String   // "same" | "other"
        public let from: String     // "A" | "B" | "any"
        public let delta: Int
    }
    public struct Incompatible: Codable, Sendable {
        public let label: String
        public let colour: String
    }
    public struct BPM: Codable, Sendable {
        public let cost_per_bpm: Double
        public let direction_cost_per_bpm: Double
    }
    public struct Defaults: Codable, Sendable {
        public let key_bpm_slider: Double
        public let bpm_tolerance: Double
        public let tempo_direction: String
        public let half_double: Bool
        public let time_budget_s: Double
        public let seed: UInt64
        public let exact_max_tracks: Int
    }

    public let transitions: [Rule]
    public let incompatible: Incompatible
    public let costs: [String: [String: Double]]
    public let bpm: BPM
    public let defaults: Defaults

    public static func load() -> HarmonicConfig {
        let url = Bundle.module.url(forResource: "config", withExtension: "json")!
        // The bundled config is part of the app; failing to read it is a build error.
        return try! JSONDecoder().decode(HarmonicConfig.self, from: Data(contentsOf: url))
    }

    public static let shared = HarmonicConfig.load()
}

// MARK: - Transition labels

public enum TransitionColour: String, Codable, Sendable {
    case green, yellow, blue, red

    public var emoji: String {
        switch self {
        case .green: "🟩"
        case .yellow: "🟨"
        case .blue: "🟦"
        case .red: "🟥"
        }
    }
}

public struct TransitionLabel: Hashable, Codable, Sendable {
    public let label: String
    public let colour: TransitionColour
}

/// Camelot-wheel label for mixing from key a into key b.
public func classify(_ a: CamelotKey, _ b: CamelotKey,
                     config: HarmonicConfig = .shared) -> TransitionLabel {
    let delta = mod(b.number - a.number, 12)
    let sameLetter = a.letter == b.letter
    for rule in config.transitions {
        if (rule.letter == "same") != sameLetter { continue }
        if rule.from != "any" && rule.from != String(a.letter) { continue }
        if mod(rule.delta, 12) == delta {
            return TransitionLabel(label: rule.label,
                                   colour: TransitionColour(rawValue: rule.colour) ?? .red)
        }
    }
    return TransitionLabel(label: config.incompatible.label,
                           colour: TransitionColour(rawValue: config.incompatible.colour) ?? .red)
}

// MARK: - Settings & costs

public enum MixMode: String, Codable, Sendable, CaseIterable { case fuzzy, mood }
public enum TempoDirection: String, Codable, Sendable, CaseIterable { case any, ascending, descending }

public struct HarmonizeSettings: Codable, Equatable, Sendable {
    public var mode: MixMode = .fuzzy
    public var keyBpmSlider: Double = 50     // 0 = key only, 100 = BPM only
    public var bpmTolerance: Double = 4
    public var tempoDirection: TempoDirection = .any
    public var halfDouble = false
    public var lockFirst: UUID?
    public var lockLast: UUID?
    public var timeBudget: Double = 10
    /// Local-search rounds for big Mixes; nil means `defaultSolverRounds`.
    /// A small count with an infinite `timeBudget` makes Harmonize cheap and,
    /// with the seed, exactly repeatable.
    public var rounds: Int?
    public var seed: UInt64 = 42

    public init() {}

    public static func defaults(_ c: HarmonicConfig = .shared) -> HarmonizeSettings {
        var s = HarmonizeSettings()
        s.keyBpmSlider = c.defaults.key_bpm_slider
        s.bpmTolerance = c.defaults.bpm_tolerance
        s.tempoDirection = TempoDirection(rawValue: c.defaults.tempo_direction) ?? .any
        s.halfDouble = c.defaults.half_double
        s.timeBudget = c.defaults.time_budget_s
        s.seed = c.defaults.seed
        return s
    }
}

public func bpmGap(_ a: Double, _ b: Double, halfDouble: Bool) -> Double {
    var gap = abs(a - b)
    if halfDouble { gap = min(gap, abs(2 * a - b), abs(a - 2 * b)) }
    return gap
}

public struct EdgeCost: Sendable {
    public let transition: TransitionLabel
    public let keyCost: Double
    public let bpmCost: Double
    public let directionCost: Double
    public let total: Double
    public let bpmDelta: Double  // signed b - a
}

public func edgeCost(_ ka: CamelotKey, _ bpmA: Double, _ kb: CamelotKey, _ bpmB: Double,
                     settings: HarmonizeSettings, config: HarmonicConfig = .shared) -> EdgeCost {
    let t = classify(ka, kb, config: config)
    let keyCost = config.costs[settings.mode.rawValue]?[t.label] ?? 0
    let tol = settings.bpmTolerance
    let excess = max(0, bpmGap(bpmA, bpmB, halfDouble: settings.halfDouble) - tol)
    let bpmCost = excess * config.bpm.cost_per_bpm
    var direction = 0.0
    if settings.tempoDirection == .ascending && bpmB < bpmA - tol {
        direction = (bpmA - tol - bpmB) * config.bpm.direction_cost_per_bpm
    } else if settings.tempoDirection == .descending && bpmB > bpmA + tol {
        direction = (bpmB - bpmA - tol) * config.bpm.direction_cost_per_bpm
    }
    let w = settings.keyBpmSlider / 100
    let total = (1 - w) * keyCost + w * bpmCost + direction
    return EdgeCost(transition: t, keyCost: keyCost, bpmCost: bpmCost,
                    directionCost: direction, total: total, bpmDelta: bpmB - bpmA)
}

/// Row-major n×n matrix; the diagonal is +infinity.
public struct CostMatrix: Sendable {
    public let n: Int
    public var values: [Double]

    public init(n: Int, values: [Double]) {
        self.n = n
        self.values = values
    }

    public subscript(i: Int, j: Int) -> Double {
        get { values[i * n + j] }
        set { values[i * n + j] = newValue }
    }

    public static func build(keys: [CamelotKey], bpms: [Double], settings: HarmonizeSettings,
                             config: HarmonicConfig = .shared) -> CostMatrix {
        let n = keys.count
        var m = CostMatrix(n: n, values: Array(repeating: .infinity, count: n * n))
        for i in 0..<n {
            for j in 0..<n where i != j {
                m[i, j] = edgeCost(keys[i], bpms[i], keys[j], bpms[j],
                                   settings: settings, config: config).total
            }
        }
        return m
    }

    public func pathCost(_ order: [Int]) -> Double {
        guard order.count > 1 else { return 0 }
        var total = 0.0
        for k in 0..<(order.count - 1) { total += self[order[k], order[k + 1]] }
        return total
    }
}
