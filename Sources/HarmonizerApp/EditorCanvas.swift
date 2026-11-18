import AppKit
import HarmonizerCore
import SwiftUI

/// Maps between timeline frames, pixels and curve x (beat fraction of a span).
struct EditorGeometry {
    let session: TransitionSession
    let width: CGFloat
    let labelWidth: CGFloat = 70

    var plotWidth: CGFloat { max(width - labelWidth, 1) }
    func x(_ frame: Double) -> CGFloat { labelWidth + CGFloat(frame / Double(session.length)) * plotWidth }
    func frame(_ x: CGFloat) -> Double { Double((x - labelWidth) / plotWidth) * Double(session.length) }

    /// Curve x (0…1 in beats) → timeline frame, for one side's beat list.
    func frame(curveX: Double, beats: [Double]) -> Double {
        let n = beats.count - 1
        guard n > 0 else { return beats.first ?? 0 }
        let pos = min(max(curveX, 0), 1) * Double(n)
        let k = min(Int(pos), n - 1)
        return beats[k] + (beats[k + 1] - beats[k]) * (pos - Double(k))
    }

    func curveX(frame: Double, beats: [Double]) -> Double {
        let n = beats.count - 1
        guard n > 0, let first = beats.first, let last = beats.last else { return 0 }
        if frame <= first { return 0 }
        if frame >= last { return 1 }
        var k = 0
        while k < n - 1 && frame > beats[k + 1] { k += 1 }
        return (Double(k) + (frame - beats[k]) / (beats[k + 1] - beats[k])) / Double(n)
    }

    /// Bar length in pixels inside the window (average over the glide).
    var pixelsPerBar: CGFloat {
        let s = session.outSpan
        return (x(Double(s.upperBound)) - x(Double(s.lowerBound))) / CGFloat(max(session.plan.bars, 1))
    }
}

struct EditorCanvas: View {
    @ObservedObject var model: TransitionEditorModel
    let session: TransitionSession
    let spec: TransitionSpec
    @Environment(\.undoManager) private var undo
    @State private var windowDrag: (kind: WindowDragKind, bars: Int)?
    @State private var delayDrag: Double?          // beats added by an in-progress delay drag
    @AppStorage("editorHintSeen") private var hintSeen = false
    @State private var showHint = false

    enum WindowDragKind { case start, end, move, incoming, delay }

    private let rulerH: CGFloat = 22, waveH: CGFloat = 76, laneH: CGFloat = 58

    var body: some View {
        GeometryReader { geo in
            let g = EditorGeometry(session: session, width: geo.size.width)
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ruler(g).frame(height: rulerH)
                    waveRow(g, isOut: true).frame(height: waveH)
                    waveRow(g, isOut: false).frame(height: waveH)
                    Divider()
                    ForEach(spec.activeLanes, id: \.self) { lane in
                        LaneRow(model: model, session: session, spec: spec, lane: lane, geometry: g)
                            .frame(height: laneH)
                        Divider()
                    }
                    addLaneRow(g)
                }
                .overlay(alignment: .topLeading) { Playhead(model: model, geometry: g) }
            }
        }
    }

    // MARK: Ruler

    private func ruler(_ g: EditorGeometry) -> some View {
        Canvas { ctx, size in
            let s = session
            ctx.fill(Path(CGRect(x: g.x(Double(s.outSpan.lowerBound)), y: 0,
                                 width: g.x(Double(s.inSpan.upperBound)) - g.x(Double(s.outSpan.lowerBound)),
                                 height: size.height)), with: .color(Ink.onCanvas.opacity(0.1)))
            for (frame, bar) in s.barMarks {
                let x = g.x(Double(frame))
                guard x >= g.labelWidth else { continue }
                let inWindow = frame >= s.outSpan.lowerBound && frame <= s.inSpan.upperBound
                ctx.fill(Path(CGRect(x: x, y: size.height - 6, width: 1, height: 6)), with: .color(.secondary))
                let pxBar = g.pixelsPerBar
                if bar % (pxBar < 14 ? 8 : pxBar < 28 ? 4 : 1) == 0 {
                    ctx.draw(Text(bar >= 0 ? "\(bar + 1)" : "\(bar)").font(.system(size: 9))
                        .foregroundStyle(inWindow ? .primary : .secondary), at: CGPoint(x: x + 3, y: 8), anchor: .leading)
                }
            }
            ctx.draw(Text("bars").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: 8, y: 11), anchor: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { p in seek(g, p.x) }
    }

    private func seek(_ g: EditorGeometry, _ x: CGFloat) {
        guard x >= g.labelWidth else { return }
        model.seek(to: Int(g.frame(x)))
    }

    // MARK: Waveforms + transition window

    private func waveRow(_ g: EditorGeometry, isOut: Bool) -> some View {
        let wave = isOut ? session.outWave : session.inWave
        let span = isOut ? session.outSpan : session.inSpan
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                drawWave(ctx, size, wave, g)
                if let info = isOut ? model.infos?.out : model.infos?.inc {
                    SectionStrip.drawDeck(ctx, info, from: g.labelWidth, to: size.width,
                                          stripY: size.height - 12, stripH: 12, cueTop: 2, cueH: size.height - 14) { px in
                        session.sourceFrame(deck: isOut ? 0 : 1, at: g.frame(px))
                    }
                }
                // Transition span + handles, offset by an in-progress drag.
                let shift = dragShift(g, isOut: isOut)
                var x0 = g.x(Double(span.lowerBound)), x1 = g.x(Double(span.upperBound))
                if isOut {
                    if windowDrag?.kind == .start || windowDrag?.kind == .move { x0 += shift }
                    if windowDrag?.kind == .end || windowDrag?.kind == .move { x1 += shift }
                }
                let rect = CGRect(x: x0, y: 2, width: max(x1 - x0, 1), height: size.height - 4)
                ctx.stroke(Path(roundedRect: rect, cornerRadius: Radius.small, style: .continuous), with: .color(Ink.accent), lineWidth: 1.5)
                ctx.fill(Path(roundedRect: rect, cornerRadius: Radius.small, style: .continuous), with: .color(Ink.accent.opacity(0.08)))
                if isOut {
                    for hx in [x0, x1] {
                        ctx.fill(Path(roundedRect: CGRect(x: hx - 3, y: size.height / 2 - 12, width: 6, height: 24),
                                      cornerRadius: Radius.hair, style: .continuous), with: .color(Ink.accent))
                    }
                } else if windowDrag?.kind == .incoming {
                    ctx.draw(Text(String(format: "%+d bars", -(windowDrag?.bars ?? 0))).font(.caption.bold()),
                             at: CGPoint(x: (x0 + x1) / 2, y: 12))
                }
                if !isOut { drawDelay(ctx, size, g) }
                ctx.fill(Path(CGRect(x: 0, y: 0, width: g.labelWidth, height: size.height)),
                         with: .color(Ink.canvas))
                ctx.draw(Text(isOut ? "Out" : "In").font(.caption.bold()).foregroundStyle(.secondary),
                         at: CGPoint(x: 8, y: size.height / 2), anchor: .leading)
                if let info = isOut ? model.infos?.out : model.infos?.inc {
                    drawDeckHeader(ctx, info, g, trailing: isOut ? nil : size.width)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3).onChanged { v in
                windowDragChanged(g, isOut: isOut, start: v.startLocation, dx: v.translation.width)
            }.onEnded { _ in windowDragEnded() })
            .onTapGesture(coordinateSpace: .local) { p in seek(g, p.x) }
        }
    }

    private func drawWave(_ ctx: GraphicsContext, _ size: CGSize, _ wave: WaveformSummary, _ g: EditorGeometry) {
        let n = wave.peak.count
        guard n > 0 else { return }
        let mid = size.height / 2
        let cols = Int(g.plotWidth)
        let dark = ctx.environment.colorScheme == .dark
        for c in 0..<cols {
            let a = c * n / cols, b = max(a + 1, (c + 1) * n / cols)
            var pk: UInt8 = 0, lo = 0, mi = 0, hi = 0
            for i in a..<min(b, n) {
                pk = max(pk, wave.peak[i]); lo += Int(wave.low[i]); mi += Int(wave.mid[i]); hi += Int(wave.high[i])
            }
            guard pk > 0 else { continue }
            let colour = Palette.waveform(low: Double(lo), mid: Double(mi), high: Double(hi), dark: dark)
            let h = Double(pk) / 255 * (mid - 3)
            ctx.fill(Path(CGRect(x: g.labelWidth + CGFloat(c), y: mid - h, width: 1, height: max(h * 2, 1))),
                     with: .color(colour))
        }
    }

    private func dragShift(_ g: EditorGeometry, isOut: Bool) -> CGFloat {
        guard let d = windowDrag else { return 0 }
        return CGFloat(d.bars) * g.pixelsPerBar
    }

    private func windowDragChanged(_ g: EditorGeometry, isOut: Bool, start: CGPoint, dx: CGFloat) {
        let kind: WindowDragKind
        if let existing = windowDrag?.kind {
            kind = existing
        } else if !isOut {
            let edge = g.x(Double(session.inSpan.lowerBound))
            kind = abs(start.x - edge) < 8 ? .delay : .incoming
        } else {
            let x0 = g.x(Double(session.outSpan.lowerBound)), x1 = g.x(Double(session.outSpan.upperBound))
            if abs(start.x - x0) < 8 { kind = .start }
            else if abs(start.x - x1) < 8 { kind = .end }
            else if start.x > x0 && start.x < x1 { kind = .move }
            else { return }
        }
        if kind == .delay {
            let beatPx = max(g.pixelsPerBar / 4, 1)
            let free = NSEvent.modifierFlags.contains(.command) && !spec.sync
            let raw = Double(dx / beatPx)
            delayDrag = max(-(session.plan.inDelay), free ? (raw * 100).rounded() / 100 : raw.rounded())
            windowDrag = (.delay, 0)
            return
        }
        var bars = Int((dx / g.pixelsPerBar).rounded())
        let current = session.plan.bars
        if kind == .start { bars = min(bars, current - 1) }        // keep at least 1 bar
        if kind == .end { bars = max(bars, 1 - current) }
        windowDrag = (kind, bars)
    }

    private func windowDragEnded() {
        guard let d = windowDrag else { return }
        windowDrag = nil
        if d.kind == .delay {
            let add = delayDrag ?? 0
            delayDrag = nil
            guard add != 0 else { return }
            let next = max(0, session.plan.inDelay + add)
            model.edit("Delay Incoming", undo: undo) { $0.inDelay = next == 0 ? nil : next }
            return
        }
        guard d.bars != 0 else { return }
        let effective = session.plan.bars
        model.edit("Move Transition", undo: undo) { s in
            switch d.kind {
            case .start: s.bars = max(1, effective - d.bars)
            case .end: s.bars = max(1, effective + d.bars); s.outNudge += d.bars
            case .move: s.outNudge += d.bars
            case .incoming: s.inNudge -= d.bars   // dragging the incoming waveform right = enter earlier in it
            case .delay: break
            }
            s.regenerateLanes()
        }
    }

    /// Title · key · BPM in a small capsule above a deck's waveform: at the
    /// left for the outgoing song, at the right edge (`trailing`) for the incoming one.
    private func drawDeckHeader(_ ctx: GraphicsContext, _ info: TrackMixInfo, _ g: EditorGeometry, trailing: CGFloat? = nil) {
        let t = info.track
        var parts = [t.title]
        if let k = t.key { parts.append(k.description + (t.keyShift != 0 ? String(format: " ↕ %+d", t.keyShift) : "")) }
        if let b = t.bpm { parts.append(String(format: "%g BPM", (b * 10).rounded() / 10)) }
        let text = ctx.resolve(Text(parts.joined(separator: " · ")).font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Ink.onBadge))
        let size = text.measure(in: CGSize(width: 600, height: 20))
        let w = size.width + 12
        let r = CGRect(x: trailing.map { $0 - w - 8 } ?? g.labelWidth + 4, y: 3, width: w, height: size.height + 4)
        ctx.fill(Capsule().path(in: r), with: .color(Ink.badge.opacity(0.6)))
        if let k = t.key {
            ctx.fill(Path(roundedRect: CGRect(x: r.minX, y: r.minY, width: 4, height: r.height), cornerRadius: Radius.hair, style: .continuous),
                     with: .color(k.wheelColour))
        }
        ctx.draw(text, at: CGPoint(x: r.minX + 7, y: r.midY), anchor: .leading)
    }

    /// The incoming delay: a hatched gap from the window start to where the
    /// incoming song starts, with its length, and a handle on the edge.
    private func drawDelay(_ ctx: GraphicsContext, _ size: CGSize, _ g: EditorGeometry) {
        let beatPx = g.pixelsPerBar / 4
        let extra = CGFloat(delayDrag ?? 0) * beatPx
        let start = g.x(Double(session.windowStart))
        let edge = g.x(Double(session.inSpan.lowerBound)) + extra
        let beats = session.plan.inDelay + (delayDrag ?? 0)
        if edge > start + 1, beats > 0 {
            let r = CGRect(x: start, y: 2, width: edge - start, height: size.height - 4)
            var hatch = Path()
            var x = r.minX - r.height
            while x < r.maxX { hatch.move(to: CGPoint(x: x, y: r.maxY)); hatch.addLine(to: CGPoint(x: x + r.height, y: r.minY)); x += 7 }
            ctx.drawLayer { l in
                l.clip(to: Path(r))
                l.stroke(hatch, with: .color(Ink.onCanvas.opacity(0.14)), lineWidth: 1)
            }
            ctx.stroke(Path(roundedRect: r, cornerRadius: Radius.small, style: .continuous), with: .color(Ink.onCanvas.opacity(0.3)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            if r.width > 40 {
                ctx.draw(Text(String(format: "+%g beat%@", (beats * 100).rounded() / 100, beats == 1 ? "" : "s"))
                            .font(.caption2.bold()).foregroundStyle(Ink.onCanvas.opacity(0.8)),
                         at: CGPoint(x: r.midX, y: r.midY))
            }
        }
        // Delay handle on the incoming box's left edge.
        ctx.fill(Path(roundedRect: CGRect(x: edge - 3, y: size.height / 2 - 12, width: 6, height: 24), cornerRadius: Radius.hair, style: .continuous),
                 with: .color(Ink.incoming))
    }

    // MARK: Lanes

    private func addLaneRow(_ g: EditorGeometry) -> some View {
        HStack {
            Menu("+ Lane") {
                ForEach(LaneKind.Group.allCases, id: \.self) { group in
                    Section(group.rawValue) {
                        ForEach(LaneKind.allCases.filter { $0.group == group && spec.lane($0) == nil }, id: \.self) { k in
                            Button(k.title) {
                                model.edit("Add \(k.title) Lane", undo: undo) { s in
                                    s.lanes[k.rawValue] = LaneSettings(k, shape: .crossfade, strength: 0.5,
                                                                       sequential: !s.sync, beats: s.beats)
                                }
                            }
                        }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(spec.activeLanes.count == LaneKind.allCases.count)
            Spacer()
            Button { showHint.toggle() } label: { Image(systemName: "questionmark.circle") }
                .buttonStyle(.borderless)
                .help("Editing gestures")
                .popover(isPresented: $showHint, arrowEdge: .top) { gestureHelp }
                .onAppear { if !hintSeen { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { showHint = true; hintSeen = true } } }
        }
        .padding(.horizontal, Space.m).frame(height: 30)
    }
}

extension EditorCanvas {
    var gestureHelp: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Editing a transition").font(.headline)
            Group {
                Label("Drag the box edges to change the length; drag inside to move it", systemImage: "arrow.left.and.right")
                Label("Drag the incoming song to choose where it enters", systemImage: "hand.draw")
                Label("Drag the incoming box's left edge to delay it (⌘: free, without sync)", systemImage: "arrow.right.to.line")
                Label("Lanes: drag points · click a line to add · double-click to delete", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                Label("⌥-drag a segment to bend it · ⌘ while dragging: no snap", systemImage: "option")
            }
            .font(.callout)
        }
        .padding(Space.xl).frame(width: 380)
    }
}

/// Vertical playhead across the editor, refreshed ~30 times a second.
struct Playhead: View {
    @ObservedObject var model: TransitionEditorModel
    let geometry: EditorGeometry

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30)) { _ in
            let pos = Double(model.position)
            let x = geometry.x(pos)
            Rectangle().fill(Ink.playhead).frame(width: 1.5)
                .offset(x: x)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
                .onAppear { model.tick() }
                .onChange(of: pos) { model.tick() }
        }
    }
}
