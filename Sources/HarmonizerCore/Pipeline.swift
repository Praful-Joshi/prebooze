import Foundation

/// The transition from one included track to the next.
public struct TransitionInfo: Sendable {
    public let from: UUID
    public let to: UUID
    public let label: TransitionLabel
    public let bpmDelta: Double
    public let cost: Double
}

public struct MixSummary: Equatable, Sendable {
    public var totalCost = 0.0
    public var green = 0, yellow = 0, blue = 0, red = 0
    public var avgBpmGap = 0.0
}

public enum HarmonizeError: Error, LocalizedError {
    case missingValues([String])
    case lockConflict
    case notEnoughTracks

    public var errorDescription: String? {
        switch self {
        case let .missingValues(names): "These tracks have no key or BPM yet:\n" + names.joined(separator: "\n")
        case .lockConflict: "First and last locked track must be different (and not joined by locked transitions)."
        case .notEnoughTracks: "Need at least two tracks."
        }
    }
}

extension MixProject {
    /// Included tracks missing a usable key or BPM.
    public var problems: [String] {
        included.filter { $0.key == nil || ($0.bpm ?? 0) <= 0 }.map(\.filename)
    }

    /// Transitions between consecutive included tracks, in the current order.
    public func transitions(settings: HarmonizeSettings? = nil) -> [TransitionInfo] {
        let s = settings ?? self.settings
        let inc = included
        guard inc.count > 1 else { return [] }
        return (0..<(inc.count - 1)).compactMap { i in
            guard let ka = inc[i].key, let kb = inc[i + 1].key,
                  let ba = inc[i].bpm, let bb = inc[i + 1].bpm else { return nil }
            let e = edgeCost(ka, ba, kb, bb, settings: s)
            return TransitionInfo(from: inc[i].id, to: inc[i + 1].id, label: e.transition,
                                  bpmDelta: e.bpmDelta, cost: e.total)
        }
    }

    public func summary(settings: HarmonizeSettings? = nil) -> MixSummary {
        summarise(transitions(settings: settings))
    }

    /// Included tracks grouped into runs joined by locked transitions, in mix
    /// order (a track on its own is a run of one).
    public var lockedChains: [[ProjectTrack]] {
        var chains: [[ProjectTrack]] = []
        for t in included {
            if let prev = chains.last?.last, transitions[MixProject.pairKey(prev.id, t.id)]?.isLocked == true {
                chains[chains.count - 1].append(t)
            } else {
                chains.append([t])
            }
        }
        return chains
    }

    /// Reorder the included tracks, keeping locked transitions' tracks together;
    /// excluded tracks keep their place at the end.
    public func harmonized(with settings: HarmonizeSettings) throws -> (MixProject, SolveResult) {
        let inc = included
        guard inc.count >= 2 else { throw HarmonizeError.notEnoughTracks }
        if !problems.isEmpty { throw HarmonizeError.missingValues(problems) }
        // Each locked chain is one node: entered at its first track, left at its last.
        let chains = lockedChains
        func cost(_ a: ProjectTrack, _ b: ProjectTrack) -> Double {
            edgeCost(a.key!, a.bpm!, b.key!, b.bpm!, settings: settings).total
        }
        var m = CostMatrix(n: chains.count, values: Array(repeating: .infinity, count: chains.count * chains.count))
        for i in chains.indices { for j in chains.indices where i != j { m[i, j] = cost(chains[i].last!, chains[j].first!) } }
        let withinChains = chains.reduce(0.0) { acc, c in acc + zip(c, c.dropFirst()).reduce(0) { $0 + cost($1.0, $1.1) } }
        let first = chains.firstIndex { $0.contains { $0.id == settings.lockFirst } }
        let last = chains.firstIndex { $0.contains { $0.id == settings.lockLast } }
        if let first, first == last { throw HarmonizeError.lockConflict }
        var result: SolveResult
        if chains.count == 1 {
            result = SolveResult(order: [0], cost: 0, method: "trivial")
        } else {
            result = try solve(m, first: first, last: last,
                               exactMax: HarmonicConfig.shared.defaults.exact_max_tracks,
                               timeBudget: settings.timeBudget, seed: settings.seed)
        }
        result = SolveResult(order: result.order, cost: result.cost + withinChains, method: result.method,
                             hitTimeLimit: result.hitTimeLimit, rounds: result.rounds)
        var out = self
        out.settings = settings
        out.tracks = result.order.flatMap { chains[$0] } + tracks.filter { !$0.include }
        out.lastRun = HarmonizeRunInfo(date: Date(), method: result.method, cost: result.cost,
                                       hitTimeLimit: result.hitTimeLimit)
        return (out, result)
    }
}

public func summarise(_ ts: [TransitionInfo]) -> MixSummary {
    var s = MixSummary()
    for t in ts {
        s.totalCost += t.cost
        switch t.label.colour {
        case .green: s.green += 1
        case .yellow: s.yellow += 1
        case .blue: s.blue += 1
        case .red: s.red += 1
        }
    }
    s.avgBpmGap = ts.isEmpty ? 0 : ts.map { abs($0.bpmDelta) }.reduce(0, +) / Double(ts.count)
    return s
}

// MARK: - Matching a pasted track order (e.g. from another app)

/// difflib.SequenceMatcher(None, a, b).ratio(): Ratcliff/Obershelp similarity,
/// 2·M / (|a| + |b|) where M counts characters in recursively found common blocks.
func similarity(_ a: String, _ b: String) -> Double {
    let x = Array(a), y = Array(b)
    guard !x.isEmpty || !y.isEmpty else { return 1 }

    func longestBlock(_ a0: Int, _ a1: Int, _ b0: Int, _ b1: Int) -> (i: Int, j: Int, len: Int) {
        var best = (i: a0, j: b0, len: 0)
        var prev = [Int](repeating: 0, count: b1 - b0 + 1)
        for i in a0..<a1 {
            var cur = [Int](repeating: 0, count: b1 - b0 + 1)
            for j in b0..<b1 where x[i] == y[j] {
                let len = prev[j - b0] + 1
                cur[j - b0 + 1] = len
                if len > best.len { best = (i - len + 1, j - len + 1, len) }
            }
            prev = cur
        }
        return best
    }

    func matched(_ a0: Int, _ a1: Int, _ b0: Int, _ b1: Int) -> Int {
        guard a0 < a1, b0 < b1 else { return 0 }
        let m = longestBlock(a0, a1, b0, b1)
        guard m.len > 0 else { return 0 }
        return m.len + matched(a0, m.i, b0, m.j) + matched(m.i + m.len, a1, m.j + m.len, b1)
    }

    return 2.0 * Double(matched(0, x.count, 0, y.count)) / Double(x.count + y.count)
}

func cleanForMatch(_ s: String) -> String {
    var t = s.lowercased()
    if let r = t.range(of: #"\.(mp3|flac|m4a|wav|aiff?|ogg|opus)$"#, options: .regularExpression) {
        t.removeSubrange(r)
    }
    t = t.replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
    return t.trimmingCharacters(in: .whitespaces)
}

/// Fuzzy-match pasted lines to included tracks. Returns matched track ids in
/// pasted order, plus lines that didn't match confidently.
public func matchTracklist(_ text: String, tracks: [ProjectTrack]) -> (matched: [UUID], unmatched: [String]) {
    let candidates = tracks.map { t in
        (id: t.id, labels: [cleanForMatch("\(t.artist) \(t.title)"),
                            cleanForMatch((t.filename as NSString).deletingPathExtension),
                            cleanForMatch(t.title)],
         title: cleanForMatch(t.title))
    }
    var used = Set<UUID>(), matched: [UUID] = [], unmatched: [String] = []
    for raw in text.split(whereSeparator: \.isNewline).map(String.init) {
        let stripped = raw.replacingOccurrences(of: #"^\s*\d+[\s.):-]+"#, with: "",
                                                options: .regularExpression)
        let line = cleanForMatch(stripped)
        guard !line.isEmpty else { continue }
        var best: UUID?, bestScore = 0.0
        let words = Set(line.split(separator: " "))
        for c in candidates where !used.contains(c.id) {
            var score = c.labels.map { similarity(line, $0) }.max() ?? 0
            if !c.title.isEmpty, Set(c.title.split(separator: " ")).isSubset(of: words) {
                score = max(score, 0.9 + 0.1 * Double(c.title.count) / Double(max(line.count, 1)))
            }
            if score > bestScore { bestScore = score; best = c.id }
        }
        if let best, bestScore >= 0.5 {
            used.insert(best)
            matched.append(best)
        } else {
            unmatched.append(raw.trimmingCharacters(in: .whitespaces))
        }
    }
    return (matched, unmatched)
}

// MARK: - Reordering with locked transitions

extension MixProject {
    /// Every track locked together with any of `ids` (its whole chain), in mix order.
    public func withLockedPartners(_ ids: Set<UUID>) -> [UUID] {
        lockedChains.filter { $0.contains { ids.contains($0.id) } }.flatMap { $0.map(\.id) }
            + tracks.filter { ids.contains($0.id) && !$0.include }.map(\.id)
    }

    /// Move tracks (with their locked partners) before `target` (nil = end).
    /// A drop inside a locked chain lands before that chain.
    public mutating func moveTracks(_ ids: Set<UUID>, before target: UUID?) {
        let moving = withLockedPartners(ids)
        let set = Set(moving)
        var anchor = target
        if let t = target, let chain = lockedChains.first(where: { $0.contains { $0.id == t } }) {
            anchor = chain.first?.id
        }
        while let a = anchor, set.contains(a) {
            // Dropped onto itself: keep the place after the moving block.
            let i = tracks.firstIndex { $0.id == a }!
            anchor = tracks[(i + 1)...].first { !set.contains($0.id) }?.id
            if anchor == nil { break }
        }
        let moved = moving.compactMap { id in tracks.first { $0.id == id } }
        tracks.removeAll { set.contains($0.id) }
        let at = anchor.flatMap { a in tracks.firstIndex { $0.id == a } } ?? tracks.endIndex
        tracks.insert(contentsOf: moved, at: at)
    }

    /// Locked transitions that touch any of these tracks.
    public func lockedTransitionKeys(touching ids: Set<UUID>) -> [String] {
        let inc = included
        return zip(inc, inc.dropFirst()).compactMap { a, b in
            let key = MixProject.pairKey(a.id, b.id)
            return (ids.contains(a.id) || ids.contains(b.id)) && transitions[key]?.isLocked == true ? key : nil
        }
    }
}
