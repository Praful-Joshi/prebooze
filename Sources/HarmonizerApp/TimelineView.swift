import AppKit
import HarmonizerCore
import SwiftUI

/// The whole mix: track blocks alternating on two rows, transitions between
/// them, a time ruler and a playhead. Click a transition to edit it, click
/// anywhere else to play from there, drag a track block to move the
/// transition into it.
struct MixTimelineView: View {
    @ObservedObject var document: MixDocument
    @ObservedObject var player: MixPlayerModel
    @ObservedObject var editor: TransitionEditorModel
    @Environment(\.undoManager) private var undo
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Pixels per second; 0 = fit the whole mix. Opens at about 12 minutes per screen.
    @State private var zoom: Double = 1.5
    @State private var pinchBase: Double?
    @State private var waves: [UUID: WaveformSummary] = [:]
    @State private var drag: (deck: Int, dx: CGFloat)?
    @State private var hover: CGPoint?
    @State private var scroll = ScrollPosition(edge: .leading)
    @State private var scrollX: CGFloat = 0
    @State private var lastUserScroll = Date.distantPast
    @State private var lastReveal = Date.distantPast
    @State private var hoverTile: CGFloat = 0

    private let rulerH: CGFloat = 18, rowH: CGFloat = 46, bandH: CGFloat = 20, tile: CGFloat = 800

    var body: some View {
        Group {
            if let layout = player.layout {
                GeometryReader { geo in
                    let fit = max(Double(geo.size.width - 4) / (Double(layout.length) / mixSampleRate), 0.02)
                    let pps = zoom > 0 ? max(zoom, fit) : fit
                    let width = CGFloat(Double(layout.length) / mixSampleRate * pps)
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 0) {
                            ForEach(0..<Int(ceil(width / tile)), id: \.self) { k in
                                tileView(layout, pps: pps, x0: CGFloat(k) * tile, w: min(tile, width - CGFloat(k) * tile))
                            }
                        }
                        .overlay(alignment: .topLeading) { playhead(pps: pps) }
                        .overlay(alignment: .topLeading) { hoverCard(layout, pps: pps) }
                    }
                    .scrollPosition($scroll)
                    .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in scrollX = x }
                    .onScrollPhaseChange { _, phase in if phase == .interacting { lastUserScroll = .now } }
                    .onChange(of: player.revealToken) {
                        reveal(pps: pps, viewWidth: geo.size.width, contentWidth: width)
                    }
                    .background {
                        // Keep the playhead on screen while playing: page ahead
                        // when it nears the right edge (or has jumped out of view).
                        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                            Color.clear.onChange(of: player.position) {
                                follow(pps: pps, viewWidth: geo.size.width, contentWidth: width)
                            }
                        }
                    }
                    .gesture(MagnifyGesture()
                        .onChanged { v in
                            let base = pinchBase ?? pps
                            if pinchBase == nil { pinchBase = pps }
                            zoom = max(fit, min(base * v.magnification, 32))
                        }
                        .onEnded { _ in pinchBase = nil; if zoom <= fit * 1.02 { zoom = 0 } })
                    .background(ScrollZoomCatcher { dy in
                        let next = pps * pow(1.01, dy)
                        zoom = next <= fit * 1.02 ? 0 : min(next, 32)
                    })
                    .overlay(alignment: .bottomTrailing) {
                        if zoom > 0 {
                            Button { withAnimation(.smooth) { zoom = 0 } } label: {
                                Image(systemName: "arrow.left.and.right.square")
                            }
                            .buttonStyle(.borderless)
                            .padding(5).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                            .padding(6)
                            .help("Fit the whole mix (pinch or ⌘-scroll to zoom)")
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .animation(.smooth(duration: 0.2), value: zoom > 0)
                }
                .frame(height: rulerH + 2 * rowH + bandH + 8)
            } else {
                Text(document.project.included.count < 2 ? "Add tracks to build a mix." : "Waiting for analysis…")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: loadWaves)
        .onChange(of: document.project.tracks) { loadWaves() }
    }

    /// Centre a song's card picked in the playlist (a card wider than the view
    /// starts near the left edge instead).
    private func reveal(pps: Double, viewWidth: CGFloat, contentWidth: CGFloat) {
        guard let r = player.revealRange, contentWidth > viewWidth + 1 else { return }
        let a = CGFloat(Double(r.lowerBound) / mixSampleRate * pps), b = CGFloat(Double(r.upperBound) / mixSampleRate * pps)
        let target = b - a <= viewWidth * 0.9 ? (a + b) / 2 - viewWidth / 2 : a - viewWidth * 0.05
        lastReveal = .now
        withAnimation(.smooth(duration: 0.5)) { scroll.scrollTo(x: min(max(0, target), contentWidth - viewWidth)) }
    }

    private func follow(pps: Double, viewWidth: CGFloat, contentWidth: CGFloat) {
        // Playing, or a jump while paused (the position only changes then).
        // Stands aside briefly after the user scrolls or a song is revealed.
        guard contentWidth > viewWidth + 1, Date.now.timeIntervalSince(lastUserScroll) > 4,
              Date.now.timeIntervalSince(lastReveal) > 1 else { return }
        let x = CGFloat(Double(player.position) / mixSampleRate * pps)
        guard x < scrollX + viewWidth * 0.05 || x > scrollX + viewWidth * 0.85 else { return }
        let target = min(max(0, x - viewWidth * 0.2), contentWidth - viewWidth)
        withAnimation(.smooth(duration: 0.6)) { scroll.scrollTo(x: target) }
    }

    private func loadWaves() {
        for t in document.project.included where waves[t.id] == nil {
            if let h = t.contentHash, let w = AnalysisCache.shared.waveform(h) { waves[t.id] = w }
        }
    }

    /// Title · key · BPM of the block under the pointer, in a soft card.
    @ViewBuilder private func hoverCard(_ layout: MixLayout, pps: Double) -> some View {
        if let p = hover, drag == nil {
            let fpx = mixSampleRate / pps
            if let d = deck(at: p, layout, x0: 0, fpx: fpx),
               let t = document.project.tracks.first(where: { $0.id == layout.decks[d].id }) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title).font(.caption.bold()).lineLimit(1)
                    Text([t.artist, t.key?.description, t.bpm.map { String(format: "%g BPM", ($0 * 100).rounded() / 100) }]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                .offset(x: p.x + 12, y: max(0, p.y - 40))
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
    }

    // MARK: Drawing

    private func tileView(_ layout: MixLayout, pps: Double, x0: CGFloat, w: CGFloat) -> some View {
        let fpx = mixSampleRate / pps   // frames per pixel
        let resolved = document.project.resolvedTransitions()
        return TimelineView(.animation(minimumInterval: 0.1, paused: !player.playing)) { _ in Canvas { ctx, size in
            func x(_ frame: Int) -> CGFloat { CGFloat(Double(frame) / fpx) - x0 }
            // Ruler.
            let stepSecs = [5.0, 10, 30, 60, 120, 300, 600].first { $0 * pps >= 60 } ?? 600
            var t = (Double(x0) / pps / stepSecs).rounded(.down) * stepSecs
            while t * pps < Double(x0 + w) {
                let px = CGFloat(t * pps) - x0
                ctx.fill(Path(CGRect(x: px, y: rulerH - 5, width: 1, height: 5)), with: .color(.secondary))
                ctx.draw(Text(TransportBar.clock(Int(t * mixSampleRate))).font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: px + 3, y: 7), anchor: .leading)
                t += stepSecs
            }
            // Transitions (band between the rows).
            let bandY = rulerH + rowH + 4
            for win in layout.windows {
                let a = x(win.globalStart), b = x(win.globalEnd)
                guard b >= 0, a <= size.width else { continue }
                let selected = win.index == editor.index
                let rect = CGRect(x: a, y: rulerH, width: max(b - a, 2), height: 2 * rowH + bandH + 4)
                ctx.fill(Path(rect), with: .color(.accentColor.opacity(selected ? 0.28 : 0.12)))
                if selected { ctx.stroke(Path(rect), with: .color(.accentColor), lineWidth: 1.5) }
                if win.index < resolved.count, b - a > 26 {
                    let r = resolved[win.index]
                    ctx.draw(Text("\(r.spec.isLocked ? "🔒 " : "")\(r.info.label.colour.emoji) \(r.spec.preset)")
                                .font(.system(size: 9, weight: .medium)),
                             in: CGRect(x: a + 3, y: bandY + 3, width: b - a - 6, height: bandH - 4))
                }
                // Countdown ring while the playhead approaches (last 8 bars before the window).
                let pos = player.position
                let approach = 8 * layout.decks[win.index].grid.barLength
                let left = Double(win.globalStart - pos)
                if player.playing, left > 0, left < approach {
                    let c = CGPoint(x: a, y: bandY + bandH / 2), rr: CGFloat = 7
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr)),
                               with: .color(.white.opacity(0.2)), lineWidth: 2)
                    var arc = Path()
                    arc.addArc(center: c, radius: rr, startAngle: .degrees(-90),
                               endAngle: .degrees(-90 + 360 * (1 - left / approach)), clockwise: false)
                    ctx.stroke(arc, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
            // Track blocks.
            for deck in layout.decks {
                var a = x(deck.globalStart), b = x(deck.globalEnd)
                if let drag, drag.deck == deck.index { a += drag.dx; b += drag.dx }
                guard b >= 0, a <= size.width else { continue }
                let y = deck.index % 2 == 0 ? rulerH + 2 : rulerH + rowH + bandH + 6
                let rect = CGRect(x: a, y: y, width: max(b - a, 1), height: rowH)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(Color(white: 0.16)))
                if let wave = waves[deck.id] { drawWave(ctx, wave, deck: deck, rect: rect, fpx: fpx, x0: x0, clip: size.width) }
                if let info = player.infos[deck.id] {
                    let lo = max(rect.minX, 0), hi = min(rect.maxX, size.width)
                    if hi > lo {
                        SectionStrip.drawDeck(ctx, info, from: lo, to: hi, stripY: rect.maxY - 10, stripH: 10,
                                              cueTop: rect.minY + 14, cueH: rect.height - 24) { px in
                            deck.sourceFrame(atGlobal: (Double(px) + Double(x0)) * fpx)
                        }
                    }
                }
                let pos = player.position
                let isPlaying = deck.globalStart <= pos && pos < deck.globalEnd
                if !isPlaying { ctx.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(.black.opacity(0.28))) }
                ctx.stroke(Path(roundedRect: rect, cornerRadius: 4),
                           with: .color(.white.opacity(isPlaying ? 0.7 : 0.18)), lineWidth: isPlaying ? 1.5 : 1)
                let title = document.project.tracks.first { $0.id == deck.id }?.title ?? deck.url.lastPathComponent
                // Title once, in the tile where the block begins (tiles are drawn separately).
                if b - a > 40, a >= -1 || x0 == 0 {
                    ctx.draw(Text("\(deck.index + 1). \(title)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white),
                             in: CGRect(x: max(a, 0) + 4, y: y + 2, width: min(b, size.width) - max(a, 0) - 8, height: 14))
                }
            }
        }
        }
        .frame(width: w, height: rulerH + 2 * rowH + bandH + 8)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            withAnimation(.easeOut(duration: 0.12)) {
                if case let .active(p) = phase { hover = CGPoint(x: p.x + x0, y: p.y) } else { hover = nil }
            }
        }
        .gesture(DragGesture(minimumDistance: 4)
            .onChanged { v in dragChanged(layout, start: v.startLocation, dx: v.translation.width, x0: x0, fpx: fpx) }
            .onEnded { _ in dragEnded(layout, fpx: fpx) })
        .onTapGesture(coordinateSpace: .local) { p in tap(layout, p, x0: x0, fpx: fpx) }
    }

    /// Analysis waveform of a deck, mapped through its in/body/out parts.
    private func drawWave(_ ctx: GraphicsContext, _ wave: WaveformSummary, deck: MixLayout.Deck, rect: CGRect,
                          fpx: Double, x0: CGFloat, clip: CGFloat) {
        let n = wave.peak.count
        let nativeK = deck.grid.sampleRate / mixSampleRate   // mix frames → native frames
        let mid = rect.midY + 6, half = (rect.height - 16) / 2
        let lo = max(rect.minX, 0), hi = min(rect.maxX, clip)
        guard hi > lo else { return }
        var px = lo
        while px < hi {
            let g = Int((Double(px) + Double(x0)) * fpx)
            let local = g - deck.globalStart
            var src: Double
            if local < deck.inLength {
                src = Double(deck.bodySource) - Double(deck.inLength - local)
            } else if local < deck.inLength + deck.bodyLength {
                src = Double(deck.bodySource + local - deck.inLength)
            } else {
                src = Double(deck.bodySource + deck.bodyLength + (local - deck.inLength - deck.bodyLength))
            }
            let variant = player.infos[deck.id]?.variant
            let a = variant?.sourceFrame(ofVirtual: src * nativeK) ?? src * nativeK
            let b = variant?.sourceFrame(ofVirtual: (src + fpx) * nativeK) ?? (src + fpx) * nativeK
            let i0 = Int(a) / WaveformSummary.bucketFrames
            let i1 = max(i0 + 1, Int(max(a, b)) / WaveformSummary.bucketFrames)
            var pk: UInt8 = 0, l = 0, m = 0, h = 0
            if i0 >= 0 && i0 < n {
                for i in i0..<min(i1, n) {
                    pk = max(pk, wave.peak[i]); l += Int(wave.low[i]); m += Int(wave.mid[i]); h += Int(wave.high[i])
                }
            }
            if pk > 0 {
                let total = Double(max(l + m + h, 1))
                let colour = Color(red: Double(l) / total * 1.6, green: Double(m) / total * 1.4, blue: Double(h) / total * 2.2)
                let height = CGFloat(Double(pk) / 255) * half
                ctx.fill(Path(CGRect(x: px, y: mid - height, width: 1, height: max(height * 2, 1))), with: .color(colour))
            }
            px += 1
        }
    }

    private func playhead(pps: Double) -> some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30)) { _ in
            Rectangle().fill(Color.white).frame(width: 1.5)
                .offset(x: CGFloat(Double(player.position) / mixSampleRate * pps))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
        }
    }

    // MARK: Interaction

    private func deck(at p: CGPoint, _ layout: MixLayout, x0: CGFloat, fpx: Double) -> Int? {
        let g = Int((Double(p.x) + Double(x0)) * fpx)
        let row = p.y < rulerH + rowH + 2 ? 0 : (p.y > rulerH + rowH + bandH + 6 ? 1 : nil)
        guard let row else { return nil }
        return layout.decks.firstIndex { $0.index % 2 == row && $0.globalStart <= g && $0.globalEnd > g }
    }

    private func tap(_ layout: MixLayout, _ p: CGPoint, x0: CGFloat, fpx: Double) {
        let g = Int((Double(p.x) + Double(x0)) * fpx)
        let bandY = rulerH + rowH + 4
        if p.y >= bandY && p.y <= bandY + bandH, let w = layout.windows.first(where: { $0.globalStart <= g && $0.globalEnd >= g }) {
            editor.select(w.index)
            return
        }
        player.seek(to: max(0, g))
    }

    private func dragChanged(_ layout: MixLayout, start: CGPoint, dx: CGFloat, x0: CGFloat, fpx: Double) {
        if drag == nil {
            guard let d = deck(at: start, layout, x0: x0, fpx: fpx), d > 0 else { return }
            drag = (d, 0)
        }
        guard let d = drag?.deck else { return }
        let barPx = CGFloat(layout.decks[d - 1].grid.barLength / fpx)
        drag = (d, (dx / barPx).rounded() * barPx)
    }

    private func dragEnded(_ layout: MixLayout, fpx: Double) {
        guard let d = drag else { return }
        drag = nil
        let barPx = CGFloat(layout.decks[d.deck - 1].grid.barLength / fpx)
        let bars = Int((d.dx / barPx).rounded())
        guard bars != 0 else { return }
        let resolved = document.project.resolvedTransitions()
        guard resolved.indices.contains(d.deck - 1) else { return }
        let t = resolved[d.deck - 1]
        document.perform("Move Transition", undo: undo) { p in
            var spec = t.spec
            spec.outNudge += bars        // the next track enters later (right) or earlier (left)
            spec.customised = true
            p.transitions[t.key] = spec
        }
        editor.refresh()
    }
}

/// ⌘-scroll over the timeline zooms (plain scroll keeps scrolling).
struct ScrollZoomCatcher: NSViewRepresentable {
    let zoom: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.view = v
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            guard e.modifierFlags.contains(.command), let view = context.coordinator.view, let w = view.window,
                  e.window == w, view.bounds.contains(view.convert(e.locationInWindow, from: nil)) else { return e }
            context.coordinator.zoom(e.scrollingDeltaY)
            return nil
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.zoom = zoom }
    func makeCoordinator() -> Coordinator { Coordinator(zoom: zoom) }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let m = coordinator.monitor { NSEvent.removeMonitor(m) }
    }

    final class Coordinator {
        var zoom: (CGFloat) -> Void
        weak var view: NSView?
        var monitor: Any?
        init(zoom: @escaping (CGFloat) -> Void) { self.zoom = zoom }
    }
}
