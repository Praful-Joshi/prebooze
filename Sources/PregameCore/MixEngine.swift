import Foundation
import os

/// One track going into the mix.
public struct MixInput: Sendable {
    public let id: UUID
    public let url: URL
    public let grid: TrackGrid    // native sample rate, of the varied audio
    public let gain: Float
    public let variant: AudioVariant
    /// Content hash, to find separated stems (nil: no stems).
    public let stemHash: String?

    public init(id: UUID, url: URL, grid: TrackGrid, gain: Float, variant: AudioVariant = AudioVariant(),
                stemHash: String? = nil) {
        self.id = id
        self.url = url
        self.grid = grid
        self.gain = gain
        self.variant = variant
        self.stemHash = stemHash
    }

    var audioKey: String { url.path + variant.signature }
}

/// Where every track and transition sits on the global mix timeline
/// (frames at `mixSampleRate`). Pure arithmetic, no audio.
public struct MixLayout: Sendable {
    public struct Window: Sendable {
        public let index: Int
        public let spec: TransitionSpec
        public let plan: TransitionPlan
        public let globalStart: Int
        public let length: Int          // whole window (sequential: out span + in span)
        public let outLength: Int       // outgoing span (synced: = length)
        public let inOffset: Int        // where the incoming span starts inside the window
        // Source frames (mix rate) on each track.
        let o0: Int, o1: Int, i0: Int, i1: Int
        let pre: Int, post: Int
        let targets: [Double]           // synced: beat boundaries inside the window
        public let outBeats: [Double]   // global frames of beat boundaries, outgoing span
        public let inBeats: [Double]    // global frames of beat boundaries, incoming span
        public let endBeatLength: Double
        /// Changes whenever the stretched audio would change.
        let signature: String

        public var globalEnd: Int { globalStart + length }
        /// Changes whenever this window's audio or placement would.
        public var signatureKey: String { signature }
        public var outSpan: Range<Int> { globalStart..<(globalStart + outLength) }
        public var inSpan: Range<Int> { (globalStart + inOffset)..<globalEnd }
    }

    public struct Deck: Sendable {
        public let index: Int
        public let id: UUID
        public let url: URL
        public let variant: AudioVariant
        let nativeRate: Double
        let stemHash: String?
        public let gain: Float
        public let grid: TrackGrid      // at mix rate
        public let globalStart: Int
        public let inLength: Int        // part inside the previous window
        public let bodyLength: Int      // untouched audio
        public let outLength: Int       // part inside the next window
        public let bodySource: Int      // source frame where the body starts
        let inSynced: Bool, outSynced: Bool

        /// Decoded (and varied) audio is stored under this key.
        public var audioKey: String { url.path + variant.signature }
        public var length: Int { inLength + bodyLength + outLength }
        public var globalEnd: Int { globalStart + length }
        public var bodyStart: Int { globalStart + inLength }
        public var bodyEnd: Int { bodyStart + bodyLength }

        /// Approximate source frame (mix rate, varied audio) heard at a global
        /// frame; stretched spans are treated as linear. Nil outside the deck.
        public func sourceFrame(atGlobal g: Double) -> Double? {
            let local = g - Double(globalStart)
            guard local >= 0, local < Double(length) else { return nil }
            if local < Double(inLength) { return Double(bodySource) - (Double(inLength) - local) * inRate }
            let b = local - Double(inLength)
            if b < Double(bodyLength) { return Double(bodySource) + b }
            return Double(bodySource + bodyLength) + (b - Double(bodyLength)) * outRate
        }

        /// Source frames per timeline frame inside the in/out windows.
        let inRate: Double, outRate: Double
    }

    public let decks: [Deck]
    public let windows: [Window]
    public let length: Int
    /// Global frame where each track "takes over" (for tracklists and cue sheets):
    /// mid-blend for synced transitions, entry for sequential ones.
    public let trackStarts: [Int]

    public init(inputs: [MixInput], plans: [TransitionPlan], echoTailBars: Int = 4) {
        let sr = mixSampleRate
        let grids = inputs.map { $0.grid.scaled(to: sr) }
        var windows: [Window] = []
        var decks: [Deck] = []
        var deckStart = 0
        var starts: [Int] = [0]
        func r(_ x: Double) -> Int { Int(x.rounded()) }

        for (i, input) in inputs.enumerated() {
            let g = grids[i]
            let prev = windows.last
            let inLength = prev.map { $0.length - $0.inOffset } ?? 0
            let bodySource = prev?.i1 ?? 0
            var outLength = 0
            var bodyEnd = g.frames
            var window: Window? = nil
            if i < plans.count {
                let p = plans[i], spec = p.spec
                let ig = grids[i + 1]
                let o0 = r(g.barFrame(Double(p.outStartBar))), o1 = r(g.barFrame(Double(p.outEndBar)))
                let i0 = r(ig.barFrame(Double(p.inStartBar))), i1 = r(ig.firstBeat + Double(p.inEndBeat) * ig.beatLength)
                bodyEnd = max(o0, bodySource)
                let bodyLen = bodyEnd - bodySource
                let start = deckStart + inLength + bodyLen
                let beats = p.beats
                let length: Int, outLen: Int, inOffset: Int
                let targets: [Double], outBeats: [Double], inBeats: [Double]
                if spec.sync {
                    // The incoming joins `inDelay` beats in, on the glide's beat.
                    targets = TempoGlide.beatTargets(from: g.bpm, to: ig.bpm, beats: beats, mode: spec.tempo, sampleRate: sr)
                    length = r(targets[beats]); outLen = length; inOffset = r(targets[beats - p.inBeats])
                    outBeats = targets.map { $0 + Double(start) }
                    inBeats = outBeats
                } else {
                    // Out, then a gap of `inDelay` incoming beats, then in.
                    targets = []
                    outLen = o1 - o0; inOffset = outLen + r(p.inDelay * ig.beatLength); length = inOffset + (i1 - i0)
                    outBeats = (0...beats).map { Double(start) + Double($0) * g.beatLength }
                    inBeats = (0...beats).map { Double(start + inOffset) + Double($0) * ig.beatLength }
                }
                let pre = min(r(g.beatLength), o0), post = min(r(ig.beatLength), ig.frames - i1)
                let sig = [input.audioKey, inputs[i + 1].audioKey, "\(o0)", "\(o1)", "\(i0)", "\(i1)",
                           "\(spec.sync)", spec.tempo.rawValue, "\(g.bpm)", "\(ig.bpm)", "\(beats)", "\(p.inDelay)"].joined(separator: "|")
                window = Window(index: i, spec: spec, plan: p, globalStart: start, length: length,
                                outLength: outLen, inOffset: inOffset, o0: o0, o1: o1, i0: i0, i1: i1,
                                pre: pre, post: post, targets: targets, outBeats: outBeats, inBeats: inBeats,
                                endBeatLength: 60 / (spec.sync ? ig.bpm : g.bpm) * sr, signature: sig)
                outLength = outLen
                starts.append(spec.sync ? start + length / 2 : start + inOffset)
            }
            decks.append(Deck(index: i, id: input.id, url: input.url, variant: input.variant,
                              nativeRate: input.grid.sampleRate, stemHash: input.stemHash, gain: input.gain, grid: g,
                              globalStart: deckStart, inLength: inLength,
                              bodyLength: max(0, bodyEnd - bodySource), outLength: outLength,
                              bodySource: bodySource, inSynced: prev?.spec.sync ?? false,
                              outSynced: window?.spec.sync ?? false,
                              inRate: prev.map { Double($0.i1 - $0.i0) / Double(max($0.length - $0.inOffset, 1)) } ?? 1,
                              outRate: window.map { Double($0.o1 - $0.o0) / Double(max($0.outLength, 1)) } ?? 1))
            if let window {
                windows.append(window)
                deckStart = window.globalStart + window.inOffset
            }
        }
        self.decks = decks
        self.windows = windows
        let lastEnd = decks.last?.globalEnd ?? 0
        let tail = windows.contains { $0.spec.lane(.echo) != nil || $0.spec.lane(.reverb) != nil }
            ? Int(Double(echoTailBars) * 4 * (windows.last?.endBeatLength ?? sr / 2)) : 0
        length = lastEnd + tail
        trackStarts = Array(starts.prefix(decks.count))
    }

    /// Decks overlapping a global frame range.
    func activeDecks(_ range: Range<Int>) -> [Int] {
        decks.indices.filter { decks[$0].globalStart < range.upperBound && decks[$0].globalEnd > range.lowerBound }
    }

    /// Index of the window whose effects (echo delay) apply at a frame.
    func windowIndex(at frame: Int) -> Int? {
        windows.lastIndex { $0.globalStart <= frame }
    }
}

/// Stretched audio for one synced window (both sides) plus the 1-beat
/// overlaps used to crossfade into the untouched audio on either side.
final class WindowAudio: @unchecked Sendable {
    let outSeg: [[Float]], head: [[Float]], inSeg: [[Float]], foot: [[Float]]

    init(_ w: MixLayout.Window, out: DecodedAudio, inc: DecodedAudio, outGrid: TrackGrid, inGrid: TrackGrid) {
        let beats = w.plan.beats
        let xf = MixEngine.joinCrossfade
        let srcO = (0...beats).map { outGrid.firstBeat + Double(w.plan.outStartBar * 4 + $0) * outGrid.beatLength - Double(w.o0) }
        let inBeats = w.plan.inBeats, delay = beats - inBeats
        let srcI = (0...inBeats).map { inGrid.firstBeat + Double(w.plan.inStartBar * 4 + $0) * inGrid.beatLength - Double(w.i0) }
        let inTargets = w.targets[delay...].map { $0 - w.targets[delay] }
        let pre = w.pre, post = w.post, n = w.length, nIn = w.length - w.inOffset
        let fullO = Stretcher.stretch(
            [Array(out.left[(w.o0 - pre)..<w.o1]), Array(out.right[(w.o0 - pre)..<w.o1])], sampleRate: mixSampleRate,
            sourcePoints: [0] + srcO.map { $0 + Double(pre) }, targetPoints: [0] + w.targets.map { $0 + Double(pre) })
        let fullI = Stretcher.stretch(
            [Array(inc.left[w.i0..<(w.i1 + post)]), Array(inc.right[w.i0..<(w.i1 + post)])], sampleRate: mixSampleRate,
            sourcePoints: srcI + [srcI[inBeats] + Double(post)], targetPoints: inTargets + [inTargets[inBeats] + Double(post)])
        outSeg = fullO.map { Array($0[pre..<(pre + n)]) }
        head = fullO.map { Array($0[max(pre - xf, 0)..<pre]) }
        inSeg = fullI.map { Array($0[0..<min(nIn, $0.count)]) }
        foot = fullI.map { Array($0[min(nIn, $0.count)..<min(nIn + xf, $0.count)]) }
    }
}

/// Plays and renders a whole mix (or any part of it, e.g. one transition with
/// lead-in/out). Untouched audio comes straight from the decoded tracks; only
/// synced windows are stretched (on demand, cached). Each deck runs through one
/// continuous EQ/filter chain, so joins stay click-free.
public final class MixEngine: @unchecked Sendable {
    static let joinCrossfade = Int(0.01 * mixSampleRate)

    /// Audio layers per deck: 0 = the track, 1–3 = its stored stems (drums,
    /// bass, vocals). Melody is the track minus those three.
    static let layerSuffix = ["", "#drums", "#bass", "#vocals"]
    static let layerStem: [StemKind?] = [nil, .drums, .bass, .vocals]

    // Shared state (UI thread writes, render thread reads with try-lock).
    private struct Shared {
        var layout: MixLayout
        var tables: [CurveTables]
        var audio: [String: DecodedAudio] = [:]      // by deck audio key (path + variant)
        var pinned: Set<String> = []                  // provided audio: never evicted or re-decoded
        var stretched: [String: WindowAudio] = [:]   // by window signature
    }
    private let shared: OSAllocatedUnfairLock<Shared>
    private var snapshot: Shared

    private struct Transport {
        var playing = false
        var position = 0
        var seek: Int?
        var range: Range<Int>?
        var loop = false
    }
    private let transport = OSAllocatedUnfairLock(initialState: Transport())

    // Render-thread state.
    private var pos = 0
    private final class DeckDSP {
        var eqL = ThreeBandEQ(sampleRate: mixSampleRate), eqR = ThreeBandEQ(sampleRate: mixSampleRate)
        var fL = DJFilter(sampleRate: mixSampleRate), fR = DJFilter(sampleRate: mixSampleRate)
    }
    private var dsp: [Int: DeckDSP] = [:]
    private let echo = EchoBus(maxDelay: Int(4 * mixSampleRate), delay: 1, feedback: 0.55, wet: 0.7)
    private let reverb = ReverbBus(sampleRate: mixSampleRate)
    private var noise = NoiseRiser()
    private let limiter: Limiter
    private let wet: Double

    public init(layout: MixLayout, config: TransitionConfig = .shared) {
        wet = config.defaults.echoWet
        let tables = MixEngine.makeTables(layout, wet: wet)
        let s = Shared(layout: layout, tables: tables)
        shared = OSAllocatedUnfairLock(initialState: s)
        snapshot = s
        limiter = Limiter(sampleRate: mixSampleRate, ceilingDb: config.defaults.limiterCeilingDb)
        dsp.reserveCapacity(8)
    }

    static func makeTables(_ layout: MixLayout, wet: Double) -> [CurveTables] {
        layout.windows.map {
            CurveTables(spec: $0.spec, outBeats: $0.outBeats, inBeats: $0.inBeats,
                        beatLength: $0.endBeatLength, wet: wet)
        }
    }

    public var layout: MixLayout { shared.withLock { $0.layout } }

    /// Replace the layout (structural edit). Stretched audio whose window
    /// didn't change is kept.
    public func update(layout: MixLayout) {
        let tables = MixEngine.makeTables(layout, wet: wet)
        shared.withLock {
            $0.layout = layout
            $0.tables = tables
            let keep = Set(layout.windows.flatMap { w in MixEngine.layerSuffix.map { w.signature + $0 } })
            $0.stretched = $0.stretched.filter { keep.contains($0.key) }
        }
    }

    /// Swap one window's curves/effects (same structure). Heard immediately.
    public func update(window index: Int, spec: TransitionSpec) {
        shared.withLock { s in
            guard s.layout.windows.indices.contains(index) else { return }
            let w = s.layout.windows[index]
            s.tables[index] = CurveTables(spec: spec, outBeats: w.outBeats, inBeats: w.inBeats,
                                          beatLength: w.endBeatLength, wet: wet)
        }
    }

    // MARK: Preparing audio

    /// Decode the decks and stretch the windows touching `range` (blocking;
    /// call off the main thread). Frees decks and windows far outside it.
    public func prepare(_ range: Range<Int>, evictOthers: Bool = true) throws {
        let layout = self.layout
        let deckIdx = layout.activeDecks(range)
        for d in deckIdx {
            let deck = layout.decks[d], key = deck.audioKey
            if shared.withLock({ $0.audio[key] }) == nil {
                let a = try AudioStore.shared.audio(deck.url, variant: deck.variant, nativeRate: deck.nativeRate)
                shared.withLock { $0.audio[key] = a }
            }
        }
        for w in layout.windows where w.spec.sync && w.globalStart < range.upperBound && w.globalEnd > range.lowerBound {
            if shared.withLock({ $0.stretched[w.signature] }) != nil { continue }
            let (out, inc) = shared.withLock { ($0.audio[layout.decks[w.index].audioKey],
                                                 $0.audio[layout.decks[w.index + 1].audioKey]) }
            guard let out, let inc else { continue }
            let audio = WindowAudio(w, out: out, inc: inc, outGrid: layout.decks[w.index].grid,
                                    inGrid: layout.decks[w.index + 1].grid)
            shared.withLock { $0.stretched[w.signature] = audio }
        }
        try prepareStems(layout, range)
        if evictOthers {
            let keepPaths = Set(deckIdx.flatMap { d in MixEngine.layerSuffix.map { layout.decks[d].audioKey + $0 } })
            let keepSigs = Set(layout.windows.filter { $0.globalStart < range.upperBound && $0.globalEnd > range.lowerBound }
                .flatMap { w in MixEngine.layerSuffix.map { w.signature + $0 } })
            shared.withLock { s in
                s.audio = s.audio.filter { keepPaths.contains($0.key) || s.pinned.contains($0.key) }
                s.stretched = s.stretched.filter { keepSigs.contains($0.key) }
            }
        }
    }

    /// Stems for windows with stem lanes in `range`: decoded from the stem
    /// cache with the deck's variant, and stretched like the track. Decks whose
    /// stems aren't separated yet simply play the track.
    private func prepareStems(_ layout: MixLayout, _ range: Range<Int>) throws {
        for w in layout.windows where w.globalStart < range.upperBound && w.globalEnd > range.lowerBound
            && LaneKind.stems.contains(where: { w.spec.lane($0) != nil }) {
            for d in [w.index, w.index + 1] {
                let deck = layout.decks[d]
                guard let hash = deck.stemHash, StemCache.shared.has(hash) else { continue }
                StemCache.shared.touch(hash)
                for layer in 1...3 {
                    let key = deck.audioKey + MixEngine.layerSuffix[layer]
                    if shared.withLock({ $0.audio[key] }) != nil { continue }
                    let stem = try decodeAudio(StemCache.shared.url(hash, MixEngine.layerStem[layer]!), sampleRate: mixSampleRate)
                    let a = deck.variant.apply(to: stem, nativeRate: deck.nativeRate)
                    shared.withLock { $0.audio[key] = a }
                }
            }
            let ready = [w.index, w.index + 1].allSatisfy { d in
                (1...3).allSatisfy { l in shared.withLock { $0.audio[layout.decks[d].audioKey + MixEngine.layerSuffix[l]] } != nil }
            }
            guard ready, w.spec.sync else { continue }
            for layer in 1...3 {
                let sig = w.signature + MixEngine.layerSuffix[layer]
                if shared.withLock({ $0.stretched[sig] }) != nil { continue }
                let suffix = MixEngine.layerSuffix[layer]
                let (out, inc) = shared.withLock { ($0.audio[layout.decks[w.index].audioKey + suffix],
                                                     $0.audio[layout.decks[w.index + 1].audioKey + suffix]) }
                guard let out, let inc else { continue }
                let audio = WindowAudio(w, out: out, inc: inc, outGrid: layout.decks[w.index].grid,
                                        inGrid: layout.decks[w.index + 1].grid)
                shared.withLock { $0.stretched[sig] = audio }
            }
        }
    }

    /// Supply already-decoded audio for a deck URL (tests, previews).
    public func provide(_ audio: DecodedAudio, for url: URL) {
        shared.withLock {
            $0.audio[url.path] = audio
            $0.pinned.insert(url.path)
        }
    }

    /// Supply an already-separated stem for a deck URL (tests).
    public func provide(_ audio: DecodedAudio, for url: URL, stem: StemKind) {
        guard let layer = MixEngine.layerStem.firstIndex(of: stem) else { return }
        let key = url.path + MixEngine.layerSuffix[layer]
        shared.withLock {
            $0.audio[key] = audio
            $0.pinned.insert(key)
        }
    }

    /// Whether everything needed to play `range` is ready.
    public func isPrepared(_ range: Range<Int>) -> Bool {
        let s = shared.withLock { $0 }
        for d in s.layout.activeDecks(range) where s.audio[s.layout.decks[d].audioKey] == nil { return false }
        for w in s.layout.windows where w.spec.sync && w.globalStart < range.upperBound && w.globalEnd > range.lowerBound {
            if s.stretched[w.signature] == nil { return false }
        }
        return true
    }

    // MARK: Transport

    public var isPlaying: Bool { transport.withLock { $0.playing } }
    public var position: Int { transport.withLock { $0.position } }
    public var playbackRange: Range<Int>? { transport.withLock { $0.range } }

    public func play() { transport.withLock { $0.playing = true } }
    public func pause() { transport.withLock { $0.playing = false } }

    public func seek(to frame: Int) {
        transport.withLock {
            let lo = $0.range?.lowerBound ?? 0
            let hi = ($0.range?.upperBound ?? Int.max) - 1
            $0.seek = max(lo, min(frame, hi))
            $0.position = $0.seek!
        }
    }

    /// Restrict playback to a range (e.g. one transition with lead-in/out).
    public func setRange(_ range: Range<Int>?, loop: Bool) {
        transport.withLock {
            $0.range = range
            $0.loop = loop
            if let range, !range.contains($0.position) {
                $0.seek = range.lowerBound
                $0.position = range.lowerBound
            }
        }
    }

    // MARK: Rendering

    private func resetDSP() {
        dsp.removeAll(keepingCapacity: true)
        echo.reset()
        reverb.reset()
        noise.reset()
        limiter.reset()
    }

    /// Audio-thread entry: fill `frames` of stereo output.
    public func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let state = transport.withLockIfAvailable { t -> Transport in
            let copy = t
            t.seek = nil
            return copy
        }
        if let s = shared.withLockIfAvailable({ $0 }) { snapshot = s }
        if let seek = state?.seek { pos = seek; resetDSP() }
        guard let state, state.playing else {
            left.update(repeating: 0, count: frames)
            right.update(repeating: 0, count: frames)
            return
        }
        let end = min(state.range?.upperBound ?? snapshot.layout.length, snapshot.layout.length)
        let start = state.range?.lowerBound ?? 0
        var written = 0
        var stopped = false
        while written < frames {
            if pos >= end {
                if state.loop { pos = start; resetDSP() } else { stopped = true; break }
            }
            let n = min(frames - written, end - pos)
            process(from: pos, count: n, left: left + written, right: right + written)
            pos += n
            written += n
        }
        if written < frames {
            (left + written).update(repeating: 0, count: frames - written)
            (right + written).update(repeating: 0, count: frames - written)
        }
        let finalPos = pos
        let ended = stopped
        transport.withLockIfAvailable {
            if $0.seek == nil { $0.position = finalPos }
            if ended { $0.playing = false; $0.seek = start; $0.position = start }
        }
    }

    /// Offline render of a range into buffers (prepares audio as it goes).
    public func renderOffline(_ range: Range<Int>, chunk requested: Int = 1 << 16,
                              _ sink: (UnsafePointer<Float>, UnsafePointer<Float>, Int) throws -> Void) throws {
        let chunk = min(requested, echoInL.count)
        let l = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
        let r = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
        defer { l.deallocate(); r.deallocate() }
        resetDSP()
        var p = range.lowerBound
        while p < range.upperBound {
            let n = min(chunk, range.upperBound - p)
            if !isPrepared(p..<(p + n)) {
                try prepare(p..<min(p + n + Int(30 * mixSampleRate), layout.length))
            }
            snapshot = shared.withLock { $0 }
            process(from: p, count: n, left: l, right: r)
            try sink(l, r, n)
            p += n
        }
    }

    /// Raw (unprocessed) audio of one deck over a global range, for drawing
    /// its waveform. Requires the range to be prepared.
    public func deckAudio(_ d: Int, _ range: Range<Int>) -> DecodedAudio {
        let s = shared.withLock { $0 }
        let src = DeckSources(s, d)
        var l = [Float](repeating: 0, count: range.count), r = l
        for (k, g) in range.enumerated() {
            let (a, b) = src.sample(g)
            l[k] = a; r[k] = b
        }
        return DecodedAudio(sampleRate: mixSampleRate, left: l, right: r)
    }

    /// Everything needed to read one deck's samples, resolved once per block.
    private struct DeckSources {
        let deck: MixLayout.Deck
        let audio: DecodedAudio?
        let inW: WindowAudio?
        let outW: WindowAudio?
        let inI0: Int
        let outO0: Int

        init(_ s: Shared, _ d: Int, layer: Int = 0) {
            let suffix = MixEngine.layerSuffix[layer]
            deck = s.layout.decks[d]
            audio = s.audio[deck.audioKey + suffix]
            if d > 0 {
                let w = s.layout.windows[d - 1]
                inW = deck.inSynced ? s.stretched[w.signature + suffix] : nil
                inI0 = w.i0
            } else { inW = nil; inI0 = 0 }
            if d < s.layout.windows.count {
                let w = s.layout.windows[d]
                outW = deck.outSynced ? s.stretched[w.signature + suffix] : nil
                outO0 = w.o0
            } else { outW = nil; outO0 = 0 }
        }

        /// Source sample at global frame g (zero outside the deck or if not ready).
        @inline(__always) func sample(_ g: Int) -> (Float, Float) {
            let local = g - deck.globalStart
            guard local >= 0, local < deck.length, let audio else { return (0, 0) }
            if local < deck.inLength {
                if deck.inSynced {
                    guard let w = inW, local < w.inSeg[0].count else { return (0, 0) }
                    return (w.inSeg[0][local], w.inSeg[1][local])
                }
                let src = inI0 + local
                return src < audio.frames ? (audio.left[src], audio.right[src]) : (0, 0)
            }
            let b = local - deck.inLength
            if b < deck.bodyLength {
                let src = deck.bodySource + b
                guard src < audio.frames else { return (0, 0) }
                var l = audio.left[src], r = audio.right[src]
                // Crossfade from the stretched incoming window into the body…
                if let w = inW {
                    let k = w.foot[0].count
                    if b < k, deck.bodyLength >= k {
                        let t = Float(b) / Float(max(k - 1, 1))
                        let rise = sin(t * .pi / 2), fall = cos(t * .pi / 2)
                        l = w.foot[0][b] * fall + l * rise
                        r = w.foot[1][b] * fall + r * rise
                    }
                }
                // …and from the body into the stretched outgoing window.
                if let w = outW {
                    let k = w.head[0].count, toEnd = deck.bodyLength - b
                    if k > 0, toEnd <= k, deck.bodyLength >= k {
                        let i = k - toEnd
                        let t = Float(i) / Float(max(k - 1, 1))
                        let rise = sin(t * .pi / 2), fall = cos(t * .pi / 2)
                        l = l * fall + w.head[0][i] * rise
                        r = r * fall + w.head[1][i] * rise
                    }
                }
                return (l, r)
            }
            let o = b - deck.bodyLength
            if deck.outSynced {
                guard let w = outW, o < w.outSeg[0].count else { return (0, 0) }
                return (w.outSeg[0][o], w.outSeg[1][o])
            }
            let src = outO0 + o
            return src < audio.frames ? (audio.left[src], audio.right[src]) : (0, 0)
        }
    }

    /// First deck that may be active at `frame` (decks are in timeline order).
    @inline(__always) private func firstActiveDeck(_ layout: MixLayout, _ frame: Int) -> Int {
        var lo = 0, hi = layout.decks.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if layout.decks[mid].globalEnd <= frame { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func process(from start: Int, count: Int, left: UnsafeMutablePointer<Float>,
                         right: UnsafeMutablePointer<Float>) {
        let s = snapshot
        let layout = s.layout
        left.update(repeating: 0, count: count)
        right.update(repeating: 0, count: count)
        var i = 0
        while i < count {
            let frame = start + i
            let block = min(CurveTables.step - (frame % CurveTables.step), count - i)
            var noiseLevel: Float = 0
            if let w = layout.windowIndex(at: frame) {
                let t = s.tables[w]
                echo.delay = t.echoDelay
                echo.feedback = t.feedback
                echo.wet = t.wet
                // The noise riser only sounds inside its window.
                let win = layout.windows[w]
                if t.hasNoise, frame >= win.globalStart, frame < win.globalEnd {
                    noiseLevel = t.out.value(.noise, at: frame)
                    noise.set(level: noiseLevel)
                }
            }
            var d = firstActiveDeck(layout, frame)
            while d < layout.decks.count && layout.decks[d].globalStart < frame + block {
                defer { d += 1 }
                let inT = d > 0 ? s.tables[d - 1] : nil
                let outT = d < layout.windows.count ? s.tables[d] : nil
                // Each side contributes its curve; outside its window it holds its edge value.
                var vol: Float = 1, lo: Float = 1, mid: Float = 1, hi: Float = 1
                var filt: Float = 0.5, send: Float = 0, verb: Float = 0
                var stem: (Float, Float, Float, Float) = (1, 1, 1, 1)
                var duck: (depth: Float, beats: [Double]) = (0, [])
                // Both sides (the window bringing this deck in, and the one taking it out).
                func addSide(_ t: CurveTables?, _ side: CurveTables.Side?, _ win: Int) {
                    guard let t, let side else { return }
                    if t.hasStems {
                        stem.0 *= side.value(.drums, at: frame); stem.1 *= side.value(.bassline, at: frame)
                        stem.2 *= side.value(.melody, at: frame); stem.3 *= side.value(.vocals, at: frame)
                    }
                    if t.hasReverb { verb += side.value(.reverb, at: frame) }
                    // Side chain ducks on the window's beats, only inside it.
                    if t.hasSidechain, frame >= layout.windows[win].globalStart, frame < layout.windows[win].globalEnd {
                        let depth = side.value(.sidechain, at: frame)
                        if depth > duck.depth { duck = (depth, side.beats) }
                    }
                }
                addSide(inT, inT?.inc, d - 1)
                addSide(outT, outT?.out, d)
                if let t = inT {
                    let c = t.inc, st = c.start
                    vol *= CurveTables.value(c.volume, start: st, at: frame, neutral: 1)
                    lo *= CurveTables.value(c.bass, start: st, at: frame, neutral: 1)
                    mid *= CurveTables.value(c.mid, start: st, at: frame, neutral: 1)
                    hi *= CurveTables.value(c.high, start: st, at: frame, neutral: 1)
                    filt += CurveTables.value(c.filter, start: st, at: frame, neutral: 0.5) - 0.5
                    send += CurveTables.value(c.echo, start: st, at: frame, neutral: 0)
                }
                if let t = outT {
                    let c = t.out, st = c.start
                    vol *= CurveTables.value(c.volume, start: st, at: frame, neutral: 1)
                    lo *= CurveTables.value(c.bass, start: st, at: frame, neutral: 1)
                    mid *= CurveTables.value(c.mid, start: st, at: frame, neutral: 1)
                    hi *= CurveTables.value(c.high, start: st, at: frame, neutral: 1)
                    filt += CurveTables.value(c.filter, start: st, at: frame, neutral: 0.5) - 0.5
                    send += CurveTables.value(c.echo, start: st, at: frame, neutral: 0)
                }
                filt = min(max(filt, 0), 1)
                let useEQ = (inT?.hasEQ ?? false) || (outT?.hasEQ ?? false)
                let useFilter = (inT?.hasFilter ?? false) || (outT?.hasFilter ?? false)
                let state: DeckDSP
                if let existing = dsp[d] { state = existing } else { state = DeckDSP(); dsp[d] = state }
                if useFilter {
                    let q = (outT?.hasFilter ?? false) ? outT!.resonance : (inT?.resonance ?? 0.9)
                    state.fL.set(value: Double(filt), resonance: q)
                    state.fR.set(value: Double(filt), resonance: q)
                }
                let src = DeckSources(s, d)
                let gainD = layout.decks[d].gain
                // Stems: melody·track + Σ (stem − melody)·stemᵢ, so all at 1 = the track.
                let useStems = stem != (1, 1, 1, 1) && s.audio[layout.decks[d].audioKey + MixEngine.layerSuffix[1]] != nil
                let s1 = DeckSources(s, d, layer: 1), s2 = DeckSources(s, d, layer: 2), s3 = DeckSources(s, d, layer: 3)
                let g1 = stem.0 - stem.2, g2 = stem.1 - stem.2, g3 = stem.3 - stem.2
                // Side-chain pump: duck at each beat, recovering over ~60 % of it.
                var phase: Double = -1, phaseStep = 0.0
                if duck.depth > 0, duck.beats.count > 1 {
                    let f = Double(frame)
                    if let k = duck.beats.lastIndex(where: { $0 <= f }), k < duck.beats.count - 1 {
                        let len = duck.beats[k + 1] - duck.beats[k]
                        phase = (f - duck.beats[k]) / len
                        phaseStep = 1 / len
                    }
                }
                for j in 0..<block {
                    var (l, r) = src.sample(frame + j)
                    if useStems {
                        let (a1, b1) = s1.sample(frame + j), (a2, b2) = s2.sample(frame + j), (a3, b3) = s3.sample(frame + j)
                        l = l * stem.2 + g1 * a1 + g2 * a2 + g3 * a3
                        r = r * stem.2 + g1 * b1 + g2 * b2 + g3 * b3
                    }
                    if phase >= 0 {
                        let p = (phase + Double(j) * phaseStep).truncatingRemainder(dividingBy: 1)
                        let env = Float(max(0, 1 - p / 0.6))
                        let g = 1 - duck.depth * env * env
                        l *= g; r *= g
                    }
                    l *= gainD; r *= gainD
                    if useEQ {
                        l = state.eqL.process(l, low: lo, mid: mid, high: hi)
                        r = state.eqR.process(r, low: lo, mid: mid, high: hi)
                    }
                    if useFilter {
                        l = state.fL.process(l)
                        r = state.fR.process(r)
                    }
                    left[i + j] += l * vol
                    right[i + j] += r * vol
                    if send > 0 {
                        echoInL[i + j] += l * send
                        echoInR[i + j] += r * send
                    }
                    if verb > 0 {
                        verbInL[i + j] += l * vol * verb
                        verbInR[i + j] += r * vol * verb
                    }
                }
            }
            for j in 0..<block {
                let (el, er) = echo.process(sendL: echoInL[i + j], sendR: echoInR[i + j])
                let (vl, vr) = reverb.process(sendL: verbInL[i + j], sendR: verbInR[i + j])
                echoInL[i + j] = 0
                echoInR[i + j] = 0
                verbInL[i + j] = 0
                verbInR[i + j] = 0
                var nl: Float = 0, nr: Float = 0
                if noiseLevel > 0 { (nl, nr) = noise.next(level: noiseLevel) }
                let (ll, rr) = limiter.process(left[i + j] + el + vl + nl, right[i + j] + er + vr + nr)
                left[i + j] = ll
                right[i + j] = rr
            }
            i += block
        }
    }

    // Echo send scratch (sized for the largest render call).
    private var echoInL = [Float](repeating: 0, count: 1 << 16)
    private var echoInR = [Float](repeating: 0, count: 1 << 16)
    private var verbInL = [Float](repeating: 0, count: 1 << 16)
    private var verbInR = [Float](repeating: 0, count: 1 << 16)
}

/// Anything the audio output can play.
public protocol AudioRenderable: AnyObject, Sendable {
    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>)
    func pause()
}

extension MixEngine: AudioRenderable {}
extension TransitionSession: AudioRenderable {}
