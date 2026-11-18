import Foundation

extension TrackGrid {
    /// The same grid expressed in frames at another sample rate.
    public func scaled(to rate: Double) -> TrackGrid {
        let k = rate / sampleRate
        return TrackGrid(frames: Int(Double(frames) * k), sampleRate: rate, firstBeat: firstBeat * k,
                         bpm: bpm, confidence: confidence)
    }
}

/// Lane curves sampled at control rate across each side's span.
final class CurveTables: @unchecked Sendable {
    static let step = 64   // frames per control value (~1.3 ms at 48 kHz)

    struct Side {
        /// One table per lane kind (empty = lane not used), by `LaneKind.index`.
        var curves = [[Float]](repeating: [], count: LaneKind.allCases.count)
        var start = 0       // timeline frame of x = 0
        /// Beat boundaries (timeline frames) of this side, for beat-synced effects.
        var beats: [Double] = []

        subscript(_ k: LaneKind) -> [Float] { curves[k.index] }
        var volume: [Float] { curves[LaneKind.volume.index] }
        var bass: [Float] { curves[LaneKind.bass.index] }
        var mid: [Float] { curves[LaneKind.mid.index] }
        var high: [Float] { curves[LaneKind.high.index] }
        var filter: [Float] { curves[LaneKind.filter.index] }
        var echo: [Float] { curves[LaneKind.echo.index] }

        /// The curve's value at a frame (`neutral` when the lane isn't used).
        @inline(__always) func value(_ k: LaneKind, at frame: Int) -> Float {
            CurveTables.value(curves[k.index], start: start, at: frame, neutral: Float(k.neutral))
        }
    }

    let out: Side, inc: Side
    let hasEQ: Bool, hasFilter: Bool, hasEcho: Bool
    let hasStems: Bool, hasNoise: Bool, hasSidechain: Bool, hasReverb: Bool
    let resonance: Double
    let echoDelay: Int, feedback: Float, wet: Float

    init(spec: TransitionSpec, outBeats: [Double], inBeats: [Double], beatLength: Double, wet: Double) {
        func sample(_ points: [Breakpoint], _ beats: [Double], neutral: Double) -> [Float] {
            guard let first = beats.first, let last = beats.last, last > first else { return [] }
            let count = Int((last - first) / Double(CurveTables.step)) + 2
            var out = [Float](repeating: Float(neutral), count: count)
            var seg = 0
            for k in 0..<count {
                let t = first + Double(k * CurveTables.step)
                while seg < beats.count - 2 && t > beats[seg + 1] { seg += 1 }
                let span = beats[seg + 1] - beats[seg]
                let frac = span > 0 ? min(max((t - beats[seg]) / span, 0), 1) : 0
                let x = (Double(seg) + frac) / Double(beats.count - 1)
                out[k] = Float(points.isEmpty ? neutral : evaluate(points, at: x))
            }
            return out
        }
        func side(_ beats: [Double], isOut: Bool) -> Side {
            var s = Side()
            s.start = Int(beats.first ?? 0)
            s.beats = beats
            for k in LaneKind.allCases {
                guard let lane = spec.lane(k) else { continue }
                s.curves[k.index] = sample(isOut ? lane.out : lane.inc, beats, neutral: k.neutral)
            }
            return s
        }
        out = side(outBeats, isOut: true)
        inc = side(inBeats, isOut: false)
        hasEQ = [LaneKind.bass, .mid, .high].contains { spec.lane($0) != nil }
        hasFilter = spec.lane(.filter) != nil
        hasEcho = spec.lane(.echo) != nil
        hasStems = LaneKind.stems.contains { spec.lane($0) != nil }
        hasNoise = spec.lane(.noise) != nil
        hasSidechain = spec.lane(.sidechain) != nil
        hasReverb = spec.lane(.reverb) != nil
        resonance = spec.lane(.filter)?.resonance ?? 0.9
        let echo = spec.lane(.echo)
        echoDelay = max(1, Int(((echo?.echoBeats ?? 2) * beatLength).rounded()))
        feedback = Float(echo?.feedback ?? 0.55)
        self.wet = Float(wet)
    }

    /// Control value at a timeline frame (edge values outside the span).
    @inline(__always) static func value(_ table: [Float], start: Int, at frame: Int, neutral: Float) -> Float {
        guard !table.isEmpty else { return neutral }
        if frame <= start { return table[0] }
        let k = (frame - start) / step
        if k >= table.count - 1 { return table[table.count - 1] }
        let f = Float((frame - start) - k * step) / Float(step)
        return table[k] + (table[k + 1] - table[k]) * f
    }
}

/// One transition, playable on its own: a two-track mix (the transition's
/// tracks) limited to the window plus lead-in/out. Uses the same engine as the
/// full mix and export, so what you preview is what gets exported. Frames in
/// this API are relative to the preview start.
public final class TransitionSession: @unchecked Sendable {
    public let sampleRate = mixSampleRate
    public let length: Int
    public let outSpan: Range<Int>
    public let inSpan: Range<Int>
    public let outBeats: [Double]
    public let inBeats: [Double]
    /// Bar starts for the ruler: (frame, bar number relative to the window, 0 = first bar).
    public let barMarks: [(frame: Int, bar: Int)]
    public let outWave: WaveformSummary
    public let inWave: WaveformSummary
    public let plan: TransitionPlan
    /// Where the window starts (for a delayed incoming, before `inSpan`).
    public let windowStart: Int

    let engine: MixEngine
    private let offset: Int
    private let range: Range<Int>
    /// Which window of `engine`'s layout this is.
    public let windowIndex: Int
    /// True when this is a view onto a shared (whole-mix) engine: transport
    /// calls then drive the whole mix rather than a private preview.
    public let shared: Bool
    /// The preview range in the mix's global frames.
    public var globalRange: Range<Int> { range }

    public enum BuildError: Error { case badPlan }

    /// A private two-track preview (tests, standalone use).
    public convenience init(plan: TransitionPlan, outAudio: DecodedAudio, inAudio: DecodedAudio,
                            outGrid: TrackGrid, inGrid: TrackGrid, gains: (Float, Float),
                            leadBars: Int, entryEndFrame: Int = 0,
                            config: TransitionConfig = .shared) throws {
        let outURL = URL(fileURLWithPath: "/preview/\(plan.from.uuidString)-out")
        let inURL = URL(fileURLWithPath: "/preview/\(plan.to.uuidString)-in")
        let inputs = [MixInput(id: plan.from, url: outURL, grid: outGrid, gain: gains.0),
                      MixInput(id: plan.to, url: inURL, grid: inGrid, gain: gains.1)]
        let layout = MixLayout(inputs: inputs, plans: [plan], echoTailBars: config.defaults.echoTailBars)
        guard let w = layout.windows.first, w.o0 >= 0, w.o1 <= outAudio.frames, w.o1 > w.o0,
              w.i0 >= 0, w.i1 <= inAudio.frames, w.i1 > w.i0 else { throw BuildError.badPlan }
        let engine = MixEngine(layout: layout, config: config)
        engine.provide(outAudio, for: outURL)
        engine.provide(inAudio, for: inURL)
        try self.init(engine: engine, window: 0, leadBars: leadBars, entryEndFrame: entryEndFrame,
                      shared: false, config: config)
    }

    /// A view of window `index` of a whole-mix engine (shared transport).
    /// Blocks while the audio around the window is prepared.
    public convenience init(mix engine: MixEngine, window index: Int, leadBars: Int,
                            config: TransitionConfig = .shared) throws {
        let layout = engine.layout
        guard layout.windows.indices.contains(index) else { throw BuildError.badPlan }
        try self.init(engine: engine, window: index, leadBars: leadBars,
                      entryEndFrame: layout.decks[index].bodyStart, shared: true, config: config)
    }

    private init(engine: MixEngine, window index: Int, leadBars: Int, entryEndFrame: Int, shared: Bool,
                 config: TransitionConfig) throws {
        let layout = engine.layout
        let w = layout.windows[index]
        let og = layout.decks[index].grid, ig = layout.decks[index + 1].grid
        let leadStart = max(w.globalStart - Int(Double(leadBars) * og.barLength), entryEndFrame, 0)
        var end = min(w.globalEnd + Int(Double(leadBars) * ig.barLength), layout.decks[index + 1].globalEnd)
        if w.spec.lane(.echo) != nil {
            let tail = Int(Double(config.defaults.echoTailBars) * 4 * w.endBeatLength)
            end = max(end, min(w.globalEnd + tail, layout.length))
        }
        range = leadStart..<end
        offset = leadStart
        length = end - leadStart
        plan = w.plan
        windowIndex = index
        self.shared = shared
        self.engine = engine
        try engine.prepare(range, evictOthers: false)
        if !shared {
            engine.setRange(range, loop: false)
            engine.seek(to: range.lowerBound)
        }

        outSpan = (w.outSpan.lowerBound - offset)..<(w.outSpan.upperBound - offset)
        inSpan = (w.inSpan.lowerBound - offset)..<(w.inSpan.upperBound - offset)
        windowStart = w.globalStart - offset
        outBeats = w.outBeats.map { $0 - Double(leadStart) }
        inBeats = w.inBeats.map { $0 - Double(leadStart) }

        var marks: [(Int, Int)] = []
        var f = Double(outSpan.lowerBound), bar = 0
        while f - og.barLength >= 0 { f -= og.barLength; bar -= 1 }
        while f < Double(outSpan.lowerBound) - 1 { marks.append((Int(f), bar)); f += og.barLength; bar += 1 }
        let windowBeats = w.spec.sync ? outBeats : outBeats + inBeats.dropFirst()
        for (k, frame) in windowBeats.enumerated() where k % 4 == 0 { marks.append((Int(frame), k / 4)) }
        bar = (marks.last?.1 ?? 0) + 1
        f = Double(max(inSpan.upperBound, outSpan.upperBound)) + ig.barLength
        while f < Double(length) { marks.append((Int(f), bar)); f += ig.barLength; bar += 1 }
        barMarks = marks

        outWave = waveformSummary(engine.deckAudio(index, range))
        inWave = waveformSummary(engine.deckAudio(index + 1, range))
    }

    /// Source frame (mix rate) of the outgoing (deck 0) or incoming (deck 1)
    /// track heard at a preview frame.
    public func sourceFrame(deck: Int, at frame: Double) -> Double? {
        engine.layout.decks[windowIndex + deck].sourceFrame(atGlobal: frame + Double(offset))
    }

    /// A preview frame as a global mix frame, and back.
    public func globalFrame(_ frame: Int) -> Int { frame + offset }
    public func localFrame(_ global: Int) -> Int { global - offset }

    // MARK: Live edits

    /// Swap in new curves/effect settings (same structure). Heard immediately.
    public func update(spec: TransitionSpec) { engine.update(window: windowIndex, spec: spec) }

    // MARK: Transport

    public var isPlaying: Bool { engine.isPlaying }
    public var position: Int { engine.position - offset }
    public func play() { engine.play() }
    public func pause() { engine.pause() }
    public func seek(to frame: Int) { engine.seek(to: frame + offset) }
    public func setLoop(_ loop: Range<Int>?) {
        engine.setRange(loop.map { ($0.lowerBound + offset)..<($0.upperBound + offset) } ?? (shared ? nil : range),
                        loop: loop != nil)
    }

    public func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        engine.render(frames: frames, left: left, right: right)
    }

    /// Render the whole preview offline (tests).
    public func renderAll() -> ([Float], [Float]) {
        var l: [Float] = [], r: [Float] = []
        l.reserveCapacity(length)
        r.reserveCapacity(length)
        try? engine.renderOffline(range) { lp, rp, n in
            l.append(contentsOf: UnsafeBufferPointer(start: lp, count: n))
            r.append(contentsOf: UnsafeBufferPointer(start: rp, count: n))
        }
        return (l, r)
    }
}
