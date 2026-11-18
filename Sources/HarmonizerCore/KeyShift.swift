import Foundation

/// A key shift that would fix a clashing (🟦/🟥) transition.
public struct KeyShiftSuggestion: Sendable {
    public let track: UUID
    public let trackTitle: String
    /// The track's new total key shift (semitones) and resulting key.
    public let shift: Int
    public let key: CamelotKey
    /// This transition after the shift.
    public let label: TransitionLabel
    /// The shifted track's other transition after the shift, if it has one.
    public let other: TransitionLabel?

    public var summary: String {
        String(format: "Shift %@ %+d → %@ (%@)", trackTitle, shift, key.description, label.label)
    }
}

extension TransitionColour {
    var rank: Int {
        switch self {
        case .green: 0
        case .yellow: 1
        case .blue: 2
        case .red: 3
        }
    }
}

extension MixProject {
    /// The smallest key shift (on either track, ±6 semitones in total) that
    /// turns transition `index` green or yellow without making the shifted
    /// track's other transition worse. Only for 🟦/🟥 transitions; nil if none.
    public func suggestKeyShift(forTransition index: Int) -> KeyShiftSuggestion? {
        let inc = included
        let ts = transitions()
        guard ts.indices.contains(index), ts[index].label.colour.rank >= 2 else { return nil }
        guard let a = inc.firstIndex(where: { $0.id == ts[index].from }), a + 1 < inc.count else { return nil }
        func edge(_ i: Int, _ j: Int, keys: [Int: CamelotKey]) -> EdgeCost? {
            guard let ki = keys[i] ?? inc[i].key, let kj = keys[j] ?? inc[j].key,
                  let bi = inc[i].bpm, let bj = inc[j].bpm else { return nil }
            return edgeCost(ki, bi, kj, bj, settings: settings)
        }
        var best: (score: (Int, Double, Int, Int), s: KeyShiftSuggestion)?
        // Try the incoming track first: on ties it wins (stable order below).
        for (pos, t) in [(a + 1, 0), (a, 1)] {
            let track = inc[pos]
            guard let base = track.baseKey else { continue }
            let otherEdge: (Int, Int)? = pos == a + 1 ? (pos + 1 < inc.count ? (pos, pos + 1) : nil)
                                                      : (pos > 0 ? (pos - 1, pos) : nil)
            let otherBefore = otherEdge.flatMap { edge($0.0, $0.1, keys: [:]) }
            for total in -6...6 where total != track.keyShift {
                let key = base.transposed(total)
                guard let e = edge(a, a + 1, keys: [pos: key]), e.transition.colour.rank <= 1 else { continue }
                let otherAfter = otherEdge.flatMap { edge($0.0, $0.1, keys: [pos: key]) }
                if let before = otherBefore, let after = otherAfter,
                   after.transition.colour.rank > before.transition.colour.rank { continue }
                let move = abs(total - track.keyShift)
                let score = (move, e.total + (otherAfter?.total ?? 0), t, abs(total))
                let s = KeyShiftSuggestion(track: track.id, trackTitle: track.title, shift: total, key: key,
                                           label: e.transition, other: otherAfter?.transition)
                if best == nil || score < best!.score { best = (score, s) }
            }
        }
        return best?.s
    }
}
