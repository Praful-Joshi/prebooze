import Foundation

/// Shortest Hamiltonian path over an asymmetric cost matrix.
/// - Held-Karp (exact) for small sets.
/// - Iterated local search (greedy starts + 2-opt + or-opt + double-bridge
///   kicks) for larger sets; deterministic for a seed unless the time budget hits.
public struct SolveResult: Sendable {
    public let order: [Int]
    public let cost: Double
    public let method: String   // "trivial" | "exact" | "heuristic"
    public var hitTimeLimit = false
    public var rounds = 0
}

public enum SolverError: Error { case sameFirstAndLast }

public func solve(_ c: CostMatrix, first: Int? = nil, last: Int? = nil,
                  exactMax: Int = 15, timeBudget: Double = 10, seed: UInt64 = 42) throws -> SolveResult {
    let n = c.n
    if let first, first == last { throw SolverError.sameFirstAndLast }
    if n <= 2 {
        var order = Array(0..<n)
        if n == 2 {
            if let first, order[0] != first { order.reverse() }
            if let last, order[1] != last { order.reverse() }
        }
        return SolveResult(order: order, cost: c.pathCost(order), method: "trivial")
    }
    if n <= exactMax {
        let order = heldKarp(c, first: first, last: last)
        return SolveResult(order: order, cost: c.pathCost(order), method: "exact")
    }
    return localSearch(c, first: first, last: last, timeBudget: timeBudget, seed: seed)
}

func heldKarp(_ c: CostMatrix, first: Int?, last: Int?) -> [Int] {
    let n = c.n
    let full = (1 << n) - 1
    var dp = [Double](repeating: .infinity, count: (1 << n) * n)
    var parent = [Int8](repeating: -1, count: (1 << n) * n)
    let starts = first.map { [$0] } ?? (0..<n).filter { $0 != last }
    for s in starts { dp[(1 << s) * n + s] = 0 }
    for mask in 1...full {
        let base = mask * n
        for i in 0..<n where mask & (1 << i) != 0 {
            let cur = dp[base + i]
            if !cur.isFinite { continue }
            for j in 0..<n where mask & (1 << j) == 0 {
                let new = mask | (1 << j)
                if let last, j == last, new != full { continue }
                let v = cur + c[i, j]
                if v < dp[new * n + j] {
                    dp[new * n + j] = v
                    parent[new * n + j] = Int8(i)
                }
            }
        }
    }
    var end = last ?? 0
    if last == nil {
        var best = Double.infinity
        for j in 0..<n where dp[full * n + j] < best {
            best = dp[full * n + j]
            end = j
        }
    }
    var order: [Int] = []
    var mask = full
    var cur = end
    while cur != -1 {
        order.append(cur)
        let prev = Int(parent[mask * n + cur])
        mask ^= 1 << cur
        cur = prev
    }
    return order.reversed()
}

/// SplitMix64: small, fast, reproducible.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func localSearch(_ input: CostMatrix, first: Int?, last: Int?, timeBudget: Double,
                 seed: UInt64, rounds: Int = 1000) -> SolveResult {
    var c = input
    for k in 0..<c.values.count where !c.values[k].isFinite { c.values[k] = 1e9 }
    let n = c.n
    var rng = SeededRandom(seed: seed)
    let deadline = Date().addingTimeInterval(timeBudget)
    let lo = first == nil ? 0 : 1
    let hi = last == nil ? n - 1 : n - 2
    var best: [Int] = []
    var bestCost = Double.infinity
    var hitLimit = false
    var done = 0
    for r in 0..<rounds {
        if Date() > deadline { hitLimit = true; break }
        var order = (best.isEmpty || r % 3 == 0)
            ? greedy(c, first: first, last: last, rng: &rng)
            : doubleBridge(best, lo: lo, hi: hi, rng: &rng)
        improve(c, &order, lo: lo, hi: hi, deadline: deadline)
        let cost = c.pathCost(order)
        if cost < bestCost - 1e-9 {
            best = order
            bestCost = cost
        }
        done = r + 1
    }
    return SolveResult(order: best, cost: input.pathCost(best), method: "heuristic",
                       hitTimeLimit: hitLimit, rounds: done)
}

private func greedy(_ c: CostMatrix, first: Int?, last: Int?,
                    rng: inout SeededRandom) -> [Int] {
    var pool = Set(0..<c.n)
    if let first { pool.remove(first) }
    if let last { pool.remove(last) }
    var cur = first ?? pool.sorted().randomElement(using: &rng)!
    pool.remove(cur)
    var order = [cur]
    while !pool.isEmpty {
        let cands = pool.sorted { (c[cur, $0], $0) < (c[cur, $1], $1) }
        // Mostly nearest neighbour, occasionally the 2nd best for diversity.
        let pick = cands.count > 1 && Double.random(in: 0..<1, using: &rng) < 0.15
            ? cands[1] : cands[0]
        order.append(pick)
        pool.remove(pick)
        cur = pick
    }
    if let last { order.append(last) }
    return order
}

private func doubleBridge(_ order: [Int], lo: Int, hi: Int, rng: inout SeededRandom) -> [Int] {
    var seg = Array(order[lo...hi])
    if seg.count < 8 {
        let picks = Array(0..<seg.count).shuffled(using: &rng).prefix(2).sorted()
        seg.swapAt(picks[0], picks[1])
    } else {
        let cuts = Array(1..<seg.count).shuffled(using: &rng).prefix(3).sorted()
        let (a, b, d) = (cuts[0], cuts[1], cuts[2])
        seg = Array(seg[..<a]) + Array(seg[b..<d]) + Array(seg[a..<b]) + Array(seg[d...])
    }
    return Array(order[..<lo]) + seg + Array(order[(hi + 1)...])
}

private func improve(_ c: CostMatrix, _ order: inout [Int], lo: Int, hi: Int, deadline: Date) {
    var improved = true
    while improved && Date() < deadline {
        improved = twoOpt(c, &order, lo: lo, hi: hi) || orOpt(c, &order, lo: lo, hi: hi)
    }
}

/// Best-improvement segment reversal (asymmetric-safe via prefix sums).
private func twoOpt(_ c: CostMatrix, _ order: inout [Int], lo: Int, hi: Int) -> Bool {
    let n = order.count
    guard hi - lo >= 1 else { return false }
    var fwd = [Double](repeating: 0, count: n)
    var bwd = [Double](repeating: 0, count: n)
    for k in 1..<n {
        fwd[k] = fwd[k - 1] + c[order[k - 1], order[k]]
        bwd[k] = bwd[k - 1] + c[order[k], order[k - 1]]
    }
    var bestDelta = -1e-9
    var bestIJ: (Int, Int)?
    for i in lo..<hi {
        for j in (i + 1)...hi {
            var delta = (bwd[j] - bwd[i]) - (fwd[j] - fwd[i])
            if i > 0 {
                let p = order[i - 1]
                delta += c[p, order[j]] - c[p, order[i]]
            }
            if j < n - 1 {
                let x = order[j + 1]
                delta += c[order[i], x] - c[order[j], x]
            }
            if delta < bestDelta {
                bestDelta = delta
                bestIJ = (i, j)
            }
        }
    }
    guard let (i, j) = bestIJ else { return false }
    order[i...j].reverse()
    return true
}

/// Move a segment of 1–8 tracks (optionally reversed) to a better position
/// (first improvement).
private func orOpt(_ c: CostMatrix, _ order: inout [Int], lo: Int, hi: Int) -> Bool {
    let n = order.count
    let maxLen = min(8, hi - lo)
    guard maxLen >= 1 else { return false }
    for length in 1...maxLen {
        for i in lo...(hi - length + 1) {
            let j = i + length - 1
            let before = i > 0 ? order[i - 1] : nil
            let after = j + 1 < n ? order[j + 1] : nil
            var removed = 0.0
            if let before { removed += c[before, order[i]] }
            if let after { removed += c[order[j], after] }
            if let before, let after { removed -= c[before, after] }
            var internalFwd = 0.0, internalRev = 0.0
            for k in i..<j {
                internalFwd += c[order[k], order[k + 1]]
                internalRev += c[order[k + 1], order[k]]
            }
            let rest = Array(order[..<i]) + Array(order[(j + 1)...])
            let rHi = hi - length + 1
            guard rHi >= lo else { continue }
            for p in lo...rHi {
                let a = p - 1 >= 0 ? rest[p - 1] : nil
                let b = p < rest.count ? rest[p] : nil
                var bridge = 0.0
                if let a, let b { bridge = c[a, b] }
                for reversed in [false, true] {
                    if p == i && !reversed { continue }
                    let head = reversed ? order[j] : order[i]
                    let tail = reversed ? order[i] : order[j]
                    var added = (reversed ? internalRev - internalFwd : 0) - bridge
                    if let a { added += c[a, head] }
                    if let b { added += c[tail, b] }
                    if added - removed < -1e-9 {
                        let seg = Array(order[i...j])
                        order = Array(rest[..<p]) + (reversed ? seg.reversed() : seg) + Array(rest[p...])
                        return true
                    }
                }
            }
        }
    }
    return false
}
