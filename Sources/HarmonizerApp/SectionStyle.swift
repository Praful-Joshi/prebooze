import HarmonizerCore
import SwiftUI

extension SectionLabel {
    var colour: Color { Ink.section(self) }
}

enum SectionStrip {
    /// Fill runs of the same section across [x0, x1) at one pixel resolution;
    /// `label(x)` gives the section heard at a pixel (nil = nothing).
    static func draw(_ ctx: GraphicsContext, y: CGFloat, height: CGFloat, from x0: CGFloat, to x1: CGFloat,
                     names: Bool = true, label: (CGFloat) -> SectionLabel?) {
        var x = x0
        var runStart = x0
        var current = label(x0)
        func flush(_ end: CGFloat) {
            guard let l = current, end > runStart else { return }
            let r = CGRect(x: runStart, y: y, width: end - runStart, height: height)
            ctx.fill(Path(r), with: .color(l.colour.opacity(0.85)))
            ctx.fill(Path(CGRect(x: runStart, y: y, width: 1, height: height)), with: .color(Ink.onSection.opacity(0.35)))
            if names, end - runStart > 34 {
                ctx.draw(Text(l.title).font(.system(size: 9, weight: .semibold)).foregroundStyle(Ink.onSection.opacity(0.85)),
                         at: CGPoint(x: runStart + 3, y: y + height / 2), anchor: .leading)
            }
        }
        while x < x1 {
            let l = label(x)
            if l != current {
                flush(x)
                runStart = x
                current = l
            }
            x += 1
        }
        flush(x1)
    }

    /// Small numbered flags for hot cues at the given x positions.
    static func drawCues(_ ctx: GraphicsContext, _ cues: [(Int, CGFloat)], top: CGFloat, height: CGFloat) {
        for (n, x) in cues {
            ctx.fill(Path(CGRect(x: x, y: top, width: 1, height: height)), with: .color(Ink.cue))
            ctx.fill(Path(roundedRect: CGRect(x: x, y: top, width: 11, height: 11), cornerRadius: Radius.hair, style: .continuous), with: .color(Ink.cue))
            ctx.draw(Text("\(n)").font(.system(size: 8, weight: .bold)).foregroundStyle(Ink.onCue),
                     at: CGPoint(x: x + 5.5, y: top + 5.5))
        }
    }
}

extension TrackMixInfo {
    /// Bar (of `grid`) at a source frame of the varied audio at the mix rate.
    func bar(atMixSource src: Double) -> Int {
        Int(((src * grid.sampleRate / mixSampleRate - grid.firstBeat) / grid.barLength).rounded(.down))
    }

    func label(atMixSource src: Double) -> SectionLabel? {
        guard let s = structure, let i = s.index(at: max(bar(atMixSource: src), 0)) else { return nil }
        return s.sections[i].label
    }

    func isLooped(atMixSource src: Double) -> Bool {
        let b = bar(atMixSource: src)
        return (introLoopBars?.contains(b) ?? false) || (outroLoopBars?.contains(b) ?? false)
    }

    /// Cue numbers whose position falls in [a, b) (mix-rate source frames).
    func cues(inMixSource a: Double, _ b: Double) -> [Int] {
        cueFrames.enumerated().compactMap { n, f in
            guard let f else { return nil }
            let m = f * mixSampleRate / grid.sampleRate
            return m >= a && m < b ? n + 1 : nil
        }
    }
}

extension SectionStrip {
    /// Sections, loop shading and cue flags for one deck, given the source
    /// frame (mix rate) heard at each pixel column.
    static func drawDeck(_ ctx: GraphicsContext, _ info: TrackMixInfo, from x0: CGFloat, to x1: CGFloat,
                         stripY: CGFloat, stripH: CGFloat, cueTop: CGFloat, cueH: CGFloat,
                         source: (CGFloat) -> Double?) {
        let cols = max(0, Int(x1 - x0))
        let src = (0...cols).map { source(x0 + CGFloat($0)) }
        draw(ctx, y: stripY, height: stripH, from: x0, to: x1) { px in
            src[min(cols, max(0, Int(px - x0)))].flatMap { info.label(atMixSource: $0) }
        }
        var cues: [(Int, CGFloat)] = []
        for c in 0..<cols {
            guard let a = src[c], let b = src[c + 1], b > a else { continue }
            if info.isLooped(atMixSource: a) {
                ctx.fill(Path(CGRect(x: x0 + CGFloat(c), y: stripY - 3, width: 1, height: 3)), with: .color(Ink.onCanvas.opacity(0.8)))
            }
            cues += info.cues(inMixSource: a, b).map { ($0, x0 + CGFloat(c)) }
        }
        drawCues(ctx, cues, top: cueTop, height: cueH)
    }
}
