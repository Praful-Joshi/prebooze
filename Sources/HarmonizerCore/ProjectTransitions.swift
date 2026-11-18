import Foundation

/// A transition between two consecutive included tracks, with its resolved spec.
public struct ResolvedTransition: Sendable {
    public let info: TransitionInfo
    public let spec: TransitionSpec
    /// Why the automatic preset was chosen (shown even when customised).
    public let reason: String
    public let key: String
}

extension MixProject {
    public static func pairKey(_ from: UUID, _ to: UUID) -> String { "\(from.uuidString)>\(to.uuidString)" }

    /// Every transition in mix order: saved edit, else imported old tweak, else automatic.
    public func resolvedTransitions(config: TransitionConfig = .shared) -> [ResolvedTransition] {
        let byId = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        return transitions().map { info in
            let key = MixProject.pairKey(info.from, info.to)
            let (auto, reason) = config.autoSpec(info.label, bpmGap: info.bpmDelta,
                                                 tolerance: settings.bpmTolerance)
            var spec = auto
            if let saved = transitions[key] {
                spec = saved
            } else if let a = byId[info.from], let b = byId[info.to],
                      let old = importedTransitions["\(a.path) → \(b.path)"],
                      let converted = TransitionSpec(legacyJSON: old, config: config) {
                spec = converted
            }
            return ResolvedTransition(info: info, spec: spec, reason: reason, key: key)
        }
    }

    /// Lock a transition (freeze its current spec and exact placement) or unlock it.
    public mutating func setTransitionLocked(_ key: String, _ on: Bool, cache: AnalysisCache = .shared) {
        guard let i = resolvedTransitions().firstIndex(where: { $0.key == key }) else { return }
        var spec = resolvedTransitions()[i].spec
        if on {
            guard let plan = plans(cache: cache)?[safe: i] else { return }
            spec.locked = plan.placement
            spec.bars = plan.bars
            spec.inDelay = plan.inDelay
            spec.customised = true
        } else {
            spec.locked = nil
        }
        transitions[key] = spec
    }

    /// Mix points for every transition, or nil while any included track lacks analysis.
    public func plans(cache: AnalysisCache = .shared) -> [TransitionPlan]? {
        guard let infos = mixInfos(cache: cache) else { return nil }
        let resolved = resolvedTransitions()
        guard resolved.count == max(infos.count - 1, 0) else { return nil }
        return planTransitions(grids: infos.map(\.grid), structures: infos.map(\.structure),
                               ids: infos.map(\.track.id), specs: resolved.map(\.spec), defaults: transitionDefaults)
    }

    /// Mix info for every included track, or nil while any lacks analysis.
    public func mixInfos(cache: AnalysisCache = .shared) -> [TrackMixInfo]? {
        var infos: [TrackMixInfo] = []
        for t in included {
            guard let info = cache.mixInfo(t) else { return nil }
            infos.append(info)
        }
        return infos
    }
}

extension TransitionSpec {
    /// Convert a tweak saved by the old web Harmonizer.
    init?(legacyJSON: String, config: TransitionConfig) {
        guard let data = legacyJSON.data(using: .utf8),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let name = d["preset"] as? String ?? "Smooth Blend"
        var spec = config.spec(preset: name)
        spec.bars = d["bars"] as? Int ?? spec.bars
        spec.sync = d["sync"] as? Bool ?? spec.sync
        spec.tempo = TempoMode(rawValue: d["tempo"] as? String ?? "") ?? spec.tempo
        spec.outNudge = d["out_nudge"] as? Int ?? 0
        spec.inNudge = d["in_nudge"] as? Int ?? 0
        if let lanes = d["lanes"] as? [String: [String: Any]] {
            spec.lanes = [:]
            for k in LaneKind.allCases {
                guard let l = lanes[k.rawValue], let shape = CurveShape(rawValue: l["curve"] as? String ?? ""),
                      shape != .none else { continue }
                spec.lanes[k.rawValue] = LaneSettings(k, shape: shape, strength: l["strength"] as? Double ?? 0.5,
                                                      swap: l["swap"] as? Double ?? 0.5,
                                                      sequential: !spec.sync, beats: spec.beats)
            }
        }
        spec.customised = true
        self = spec
    }
}

extension Array {
    public subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
