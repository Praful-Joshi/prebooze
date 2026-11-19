import Foundation

// MARK: - Model

public enum SectionLabel: String, Codable, CaseIterable, Sendable {
    case intro, build, drop, breakdown = "break", outro

    public var title: String {
        switch self {
        case .intro: "Intro"
        case .build: "Build"
        case .drop: "Drop"
        case .breakdown: "Break"
        case .outro: "Outro"
        }
    }
}

public struct Section: Codable, Equatable, Sendable {
    public var startBar: Int
    public var label: SectionLabel

    public init(_ startBar: Int, _ label: SectionLabel) {
        self.startBar = startBar
        self.label = label
    }
}

/// A track's sections in bars of the grid it was made on (`firstBeat`, `bpm`,
/// native frames). `rebased(to:)` moves it onto another grid (BPM override,
/// corrected downbeat, loops).
public struct TrackStructure: Codable, Equatable, Sendable {
    /// Sorted by start; the first starts at bar 0; each runs to the next (the last to `bars`).
    public var sections: [Section]
    public var bars: Int
    /// 0–1: how clearly the sections stand apart (low → mix on phrases instead).
    public var confidence: Double
    /// Phrases (8 bars) start on bars ≡ phraseOffset (mod 8).
    public var phraseOffset: Int
    public var firstBeat: Double
    public var bpm: Double
    public var sampleRate: Double
    /// True when the user corrected it.
    public var edited = false

    public init(sections: [Section], bars: Int, confidence: Double, phraseOffset: Int,
                firstBeat: Double, bpm: Double, sampleRate: Double) {
        self.sections = sections
        self.bars = bars
        self.confidence = confidence
        self.phraseOffset = phraseOffset
        self.firstBeat = firstBeat
        self.bpm = bpm
        self.sampleRate = sampleRate
    }

    public func range(_ i: Int) -> Range<Int> {
        sections[i].startBar..<(i + 1 < sections.count ? sections[i + 1].startBar : bars)
    }

    public func index(at bar: Int) -> Int? { sections.lastIndex { $0.startBar <= bar } }

    public var firstDrop: Int? { sections.first { $0.label == .drop }?.startBar }
    /// Where the outgoing track starts to leave: its outro, else its last break.
    public var exitBar: Int? {
        if let i = sections.indices.last(where: { sections[$0].label == .outro }),
           i > 0 || sections.count == 1 {
            // Start of the run of outro sections at the end.
            var j = i
            while j > 0 && sections[j - 1].label == .outro { j -= 1 }
            return sections[j].startBar
        }
        return sections.last { $0.label == .breakdown }?.startBar
    }
    /// Where the incoming track should be fully in: its first drop when only
    /// intro/build come before it, else the end of the intro.
    public var entryBar: Int? {
        if let i = sections.firstIndex(where: { $0.label == .drop }), i > 0,
           sections[..<i].allSatisfy({ $0.label == .intro || $0.label == .build }) {
            return sections[i].startBar
        }
        return introEnd
    }

    public var introEnd: Int? {
        guard sections.first?.label == .intro else { return nil }
        return range(sections.lastIndex { $0.label == .intro }!).upperBound
    }

    /// Phrase boundaries (every 8 bars from the offset) plus section starts.
    public var phraseBars: [Int] {
        var s = Set(stride(from: phraseOffset, through: bars, by: 8))
        sections.forEach { s.insert($0.startBar) }
        return s.sorted()
    }

    /// The same sections expressed in bars of `grid` (rounded to the nearest bar).
    public func rebased(to grid: TrackGrid) -> TrackStructure {
        let k = grid.sampleRate / sampleRate
        let srcBar = 4 * 60 / bpm * sampleRate
        func map(_ bar: Int) -> Int {
            let frame = (firstBeat + Double(bar) * srcBar) * k
            return Int(((frame - grid.firstBeat) / grid.barLength).rounded())
        }
        if abs(firstBeat * k - grid.firstBeat) < 1, abs(bpm - grid.bpm) < 1e-9, bars == grid.bars {
            return self
        }
        var out = self
        out.sections = []
        for s in sections {
            let b = max(0, min(map(s.startBar), grid.bars - 1))
            if let last = out.sections.last, last.startBar >= b { continue }
            out.sections.append(Section(out.sections.isEmpty ? 0 : b, s.label))
        }
        if out.sections.isEmpty { out.sections = [Section(0, sections.first?.label ?? .drop)] }
        out.bars = grid.bars
        out.phraseOffset = mod(map(phraseOffset), 8)
        out.firstBeat = grid.firstBeat
        out.bpm = grid.bpm
        out.sampleRate = grid.sampleRate
        return out
    }

    /// `count` extra bars repeated at `bar` (a loop): sections after it move later.
    public func inserting(bars count: Int, at bar: Int) -> TrackStructure {
        guard count > 0 else { return self }
        var out = self
        out.sections = sections.map { $0.startBar > bar ? Section($0.startBar + count, $0.label) : $0 }
        out.bars += count
        return out
    }

    // MARK: Editing

    /// Move the start of section `i` (not the first) between its neighbours.
    public mutating func moveBoundary(_ i: Int, to bar: Int) {
        guard i > 0, i < sections.count else { return }
        let lo = sections[i - 1].startBar + 1
        let hi = (i + 1 < sections.count ? sections[i + 1].startBar : bars) - 1
        guard lo <= hi else { return }
        sections[i].startBar = max(lo, min(bar, hi))
        edited = true
    }

    /// Split the section containing `bar` there (the new part keeps the label).
    public mutating func split(at bar: Int, label: SectionLabel? = nil) {
        guard bar > 0, bar < bars, let i = index(at: bar), sections[i].startBar != bar else { return }
        sections.insert(Section(bar, label ?? sections[i].label), at: i + 1)
        edited = true
    }

    /// Remove section `i`'s start, joining it to the previous section.
    public mutating func merge(_ i: Int) {
        guard i > 0, i < sections.count else { return }
        sections.remove(at: i)
        edited = true
    }

    public mutating func relabel(_ i: Int, _ label: SectionLabel) {
        guard sections.indices.contains(i) else { return }
        sections[i].label = label
        edited = true
    }
}

// MARK: - Features

/// Band levels (dB) per beat from a grid anchor.
struct BeatFeatures {
    var bass: [Float]
    var full: [Float]
    var high: [Float]
    /// Low band in the second half of each beat: a bassline between the kicks.
    var offBass: [Float] = []
    var mid: [Float] = []
    var count: Int { bass.count }

    /// Average over consecutive groups of `size` beats starting at `offset`.
    /// Silence counts as 35 dB below the loud parts, so a silent start or end
    /// doesn't dwarf the changes inside the music.
    func floored() -> BeatFeatures {
        func f(_ x: [Float]) -> [Float] {
            let floor = percentile(x, 95) - 35
            return x.map { max($0, floor) }
        }
        return BeatFeatures(bass: f(bass), full: f(full), high: f(high), offBass: f(offBass), mid: f(mid))
    }

    func grouped(_ size: Int, offset: Int = 0) -> BeatFeatures {
        func g(_ x: [Float]) -> [Float] {
            stride(from: offset, to: x.count - size + 1, by: size).map { s in
                // Average power, back in dB.
                let p = x[s..<(s + size)].reduce(0) { $0 + pow(10, $1 / 10) } / Float(size)
                return 10 * log10(max(p, 1e-10))
            }
        }
        return BeatFeatures(bass: g(bass), full: g(full), high: g(high), offBass: g(offBass), mid: g(mid))
    }
}

func beatFeatures(_ mono: [Float], sampleRate: Double, firstBeat: Double, bpm: Double) -> BeatFeatures {
    let low = Biquad.lowpass(150, sampleRate: sampleRate).apply(mono)
    let high = Biquad.highpass(4000, sampleRate: sampleRate).apply(mono)
    let midBand = Biquad.lowpass(4000, sampleRate: sampleRate).apply(Biquad.highpass(300, sampleRate: sampleRate).apply(mono))
    let beat = 60 / bpm * sampleRate
    let n = max(0, Int((Double(mono.count) - firstBeat) / beat))
    var f = BeatFeatures(bass: [], full: [], high: [])
    func db(_ acc: Double, _ k: Int) -> Float { Float(10 * log10(max(acc / Double(max(k, 1)), 1e-10))) }
    for b in 0..<n {
        let s = Int(firstBeat + Double(b) * beat), e = min(Int(firstBeat + Double(b + 1) * beat), mono.count)
        let half = s + (e - s) / 2
        var l = 0.0, a = 0.0, h = 0.0, m = 0.0, off = 0.0
        for i in s..<e {
            let li = Double(low[i] * low[i])
            l += li; a += Double(mono[i] * mono[i]); h += Double(high[i] * high[i]); m += Double(midBand[i] * midBand[i])
            if i >= half { off += li }
        }
        f.bass.append(db(l, e - s)); f.full.append(db(a, e - s)); f.high.append(db(h, e - s))
        f.mid.append(db(m, e - s)); f.offBass.append(db(off, e - half))
    }
    return f
}

/// How much the sound changes at each step: distance (dB) between the mean
/// levels of the `half` steps before and after it (0 near the ends, where a
/// window would be cut short).
func novelty(_ f: BeatFeatures, half: Int) -> [Float] {
    let n = f.count
    var out = [Float](repeating: 0, count: n)
    guard n > 2 * half else { return out }
    func mean(_ x: [Float], _ r: Range<Int>) -> Float { x[r].reduce(0, +) / Float(r.count) }
    for k in half...(n - half) where k < n {
        let a = (k - half)..<k, b = k..<(k + half)
        let d0 = mean(f.bass, b) - mean(f.bass, a)
        let d1 = mean(f.full, b) - mean(f.full, a)
        let d2 = mean(f.high, b) - mean(f.high, a)
        out[k] = (d0 * d0 + 0.5 * d1 * d1 + 0.5 * d2 * d2).squareRoot()
    }
    return out
}

/// How much the low end comes in at each step (drops land on downbeats; the
/// cut just before them doesn't count).
func rise(_ f: BeatFeatures, half: Int) -> [Float] {
    let n = f.count
    var out = [Float](repeating: 0, count: n)
    guard n > 2 * half else { return out }
    func mean(_ x: [Float], _ r: Range<Int>) -> Float { x[r].reduce(0, +) / Float(r.count) }
    // A shorter window before is fine near the start: music coming in after
    // silence should count on its first beat.
    for k in 1...(n - half) {
        let a = max(0, k - half)..<k, b = k..<(k + half)
        out[k] = max(0, mean(f.bass, b) - mean(f.bass, a)) + max(0, mean(f.full, b) - mean(f.full, a))
    }
    return out
}

/// The phase (0..<period) where the clear changes (novelty peaks) happen.
/// Keeps 0 unless another phase is clearly stronger. Returns (phase, confidence 0–1).
func strongestPhase(_ nov: [Float], period: Int, prior: Int = 0) -> (Int, Double) {
    var score = [Double](repeating: 0, count: period)
    let top = nov.max() ?? 0
    for k in 1..<max(1, nov.count - 1)
    where nov[k] > nov[k - 1] && nov[k] >= nov[k + 1] && nov[k] >= max(0.3 * top, 2) {
        score[k % period] += Double(nov[k])
    }
    guard score.contains(where: { $0 > 0 }) else { return (prior, 0) }
    let best = score.indices.max { score[$0] < score[$1] } ?? 0
    let others = score.enumerated().filter { $0.offset != best }.map(\.element)
    let runnerUp = others.max() ?? 0
    let confidence = score[best] > 0 ? 1 - runnerUp / score[best] : 0
    if best != prior, score[best] < 1.2 * score[prior] { return (prior, 0) }
    return (best, confidence)
}

// MARK: - Detection

/// Sections from per-bar band levels (dB). Pure: tests feed it synthetic levels.
func detectSections(_ bars: BeatFeatures) -> (sections: [Section], phraseOffset: Int, confidence: Double) {
    let n = bars.count
    guard n >= 16 else { return ([Section(0, .drop)], 0, 0) }
    let bars = bars.floored()
    let nov = novelty(bars, half: 4)
    let (offset, _) = strongestPhase(rise(bars, half: 4), period: 8)

    // Boundaries: strong local peaks of change, ≥ 8 bars apart, preferring
    // 4-bar steps of the phrase grid (some tracks shift phrase mid-way).
    let top = nov.max() ?? 0
    let threshold = max(5, 0.2 * top)
    func weight(_ b: Int) -> Float { nov[b] * (mod(b - offset, 4) == 0 ? 1 : 0.75) }
    var cands = (4..<max(4, n - 3)).filter { b in
        nov[b] >= threshold && (max(0, b - 2)...min(n - 1, b + 2)).allSatisfy { weight($0) <= weight(b) }
    }
    cands.sort { weight($0) > weight($1) }
    var bounds: [Int] = []
    for c in cands where bounds.allSatisfy({ abs($0 - c) >= 8 }) { bounds.append(c) }
    bounds = [0] + bounds.sorted()
    if let last = bounds.last, n - last < 4, bounds.count > 1 { bounds.removeLast() }

    // Energy per section; "full" sections are within 4.5 dB of the track's loud bars.
    let energy = (0..<n).map { 0.6 * bars.bass[$0] + 0.4 * bars.full[$0] }
    let ref = percentile(energy, 90)
    func range(_ i: Int) -> Range<Int> { bounds[i]..<(i + 1 < bounds.count ? bounds[i + 1] : n) }
    let level = bounds.indices.map { i -> Float in
        let r = range(i)
        return energy[r].reduce(0, +) / Float(r.count)
    }
    let full = level.map { $0 >= ref - 4.5 }
    var labels = [SectionLabel](repeating: .drop, count: bounds.count)
    if let firstFull = full.firstIndex(of: true), let lastFull = full.lastIndex(of: true) {
        for i in bounds.indices where !full[i] {
            if i < firstFull { labels[i] = .intro }
            else if i > lastFull { labels[i] = .outro }
            else { labels[i] = .breakdown }
        }
        // The low section right before a drop builds into it when there is
        // more than one low section in that run.
        for i in bounds.indices.dropFirst() where full[i] && !full[i - 1] && i - 1 > 0 && !full[i - 2] {
            labels[i - 1] = .build
        }
    } else {
        for i in bounds.indices { labels[i] = i == 0 ? .intro : (i == bounds.count - 1 ? .outro : .breakdown) }
    }
    // Confidence: contrast between drops and the rest, the expected parts
    // being present, and boundaries sitting on the phrase grid.
    let fullLevels = level.indices.filter { full[$0] }.map { level[$0] }
    let lowLevels = level.indices.filter { !full[$0] }.map { level[$0] }
    let contrast: Double = lowLevels.isEmpty || fullLevels.isEmpty ? 0.2
        : min(1, max(0, Double(percentile(fullLevels, 50) - percentile(lowLevels, 50)) / 9))
    let present = [SectionLabel.intro, .drop, .outro].filter { labels.contains($0) }.count
    let onGrid = bounds.count > 1
        ? Double(bounds.dropFirst().filter { mod($0 - offset, 8) == 0 }.count) / Double(bounds.count - 1) : 0
    let confidence = 0.5 * contrast + 0.25 * Double(present) / 3 + 0.25 * onGrid

    // DJ-wise the first part is always the way in and the last the way out,
    // even with full drums. A long full part at either end keeps its drop and
    // gets a 16-bar intro/outro (on the phrase grid).
    if bounds.count >= 3 || !full.contains(false) {
        let last = bounds.count - 1
        if full[last], n - bounds[last] >= 32 {
            let cut = bounds[last] + ((n - 16 - bounds[last] - offset) / 8) * 8 + offset
            if cut > bounds[last] + 8, cut < n - 4 { bounds.append(cut); labels.append(.outro) }
            else { labels[last] = .outro }
        } else {
            labels[last] = .outro
        }
        let firstEnd = bounds.count > 1 ? bounds[1] : n
        if full[0], firstEnd >= 32 {
            let cut = 16 + offset
            if cut < firstEnd - 8 { bounds.insert(cut, at: 1); labels.insert(.drop, at: 1) }
        }
        labels[0] = .intro
    }
    var sections: [Section] = []
    for (b, l) in zip(bounds, labels) where sections.last?.label != l { sections.append(Section(b, l)) }

    // A long break whose highs climb at the end has a build there.
    func mean(_ x: [Float], _ q: Range<Int>) -> Float { x[q].reduce(0, +) / Float(q.count) }
    for i in sections.indices.reversed() where sections[i].label == .breakdown {
        let r = sections[i].startBar..<(i + 1 < sections.count ? sections[i + 1].startBar : n)
        guard r.count >= 16, i + 1 < sections.count, sections[i + 1].label == .drop else { continue }
        let tail = (r.upperBound - 8)..<r.upperBound, head = r.lowerBound..<(r.upperBound - 8)
        if mean(bars.high, tail) - mean(bars.high, head) >= 3 {
            sections.insert(Section(tail.lowerBound, .build), at: i + 1)
        }
    }
    return (sections, offset, confidence)
}

/// Bar 1 (the track's earliest downbeat) and song structure, given any frame
/// on the beat (`beatAnchor`, e.g. the first strong kick, which is assumed to
/// be a downbeat unless the changes in the music say otherwise).
func analyseStructure(_ mono: [Float], sampleRate: Double, beatAnchor: Double,
                      bpm: Double) -> (firstBeat: Double, structure: TrackStructure) {
    let beat = 60 / bpm * sampleRate
    let earliest = beatAnchor - (beatAnchor / beat).rounded(.down) * beat
    let anchorIndex = Int(((beatAnchor - earliest) / beat).rounded())
    let beats = beatFeatures(mono, sampleRate: sampleRate, firstBeat: earliest, bpm: bpm).floored()
    let (phase, _) = strongestPhase(rise(beats, half: 4), period: 4, prior: anchorIndex % 4)
    let downbeat = earliest + Double(phase) * beat
    let bars = beats.grouped(4, offset: phase)
    let (sections, offset, confidence) = detectSections(bars)
    let structure = TrackStructure(sections: sections, bars: bars.count, confidence: confidence,
                                   phraseOffset: offset, firstBeat: downbeat, bpm: bpm,
                                   sampleRate: sampleRate)
    return (downbeat, structure)
}
