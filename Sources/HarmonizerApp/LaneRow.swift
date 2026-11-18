import AppKit
import HarmonizerCore
import SwiftUI

/// One automation lane: outgoing curve (solid orange) and incoming curve
/// (dashed blue) drawn over the transition, editable by dragging.
struct LaneRow: View {
    @ObservedObject var model: TransitionEditorModel
    let session: TransitionSession
    let spec: TransitionSpec
    let lane: LaneKind
    let geometry: EditorGeometry
    @Environment(\.undoManager) private var undo
    @State private var target: Target?
    @State private var moved = false

    enum Side { case out, inc }
    enum Target {
        case point(Side, Int)
        case bend(Side, Int, Double)   // segment index, bend at drag start
        case none
    }

    private let pad: CGFloat = 6
    private let outColour = Color(red: 1, green: 0.55, blue: 0.15)
    private let inColour = Color(red: 0.35, green: 0.65, blue: 1)

    private var settings: LaneSettings? { spec.lane(lane) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in draw(ctx, size) }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { v in changed(v, height: geometryHeight) }
                    .onEnded { v in ended(v, height: geometryHeight) })
            header.frame(width: geometry.labelWidth - 6, alignment: .leading).padding(.leading, 6).padding(.top, 4)
        }
        .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
        .onPreferenceChange(HeightKey.self) { geometryHeight = $0 }
    }

    @State private var geometryHeight: CGFloat = 58

    // MARK: Header

    @State private var headerHover = false

    private var glyph: String {
        switch settings?.shape {
        case .crossfade: "✕"
        case .fadeIn: "↗"
        case .fadeOut: "↘"
        case .swap: "⇄"
        case .manual: "✎"
        default: "–"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(lane.title).font(.caption.bold())
                if !headerHover { Text(glyph).font(.caption2).foregroundStyle(.secondary) }
            }
            if headerHover { headerMenu.fixedSize().transition(.opacity) }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { headerHover = h } }
    }

    private var headerMenu: some View {
            Menu(settings.map { $0.shape == .manual || $0.shape == .none ? $0.shape.title : "\($0.shape.title) \(Int($0.strength * 100))%" } ?? "") {
                ForEach([CurveShape.crossfade, .fadeIn, .fadeOut, .swap], id: \.self) { shape in
                    Menu(shape.title) {
                        ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { strength in
                            Button("\(Int(strength * 100))%") { setShape(shape, strength: strength) }
                        }
                    }
                }
                Button(CurveShape.none.title) { setShape(.none, strength: settings?.strength ?? 0.5) }
                Divider()
                if lane == .filter {
                    Menu("Resonance") {
                        ForEach([0.7, 0.9, 1.5, 2.5, 4.0], id: \.self) { q in
                            Button(String(format: "Q %.1f", q)) {
                                model.edit("Filter Resonance", undo: undo) { $0.lanes[lane.rawValue]?.resonance = q }
                            }
                        }
                    }
                }
                if lane == .echo {
                    Menu("Delay") {
                        ForEach([(0.75, "¾ beat"), (1, "1 beat"), (2, "½ bar"), (4, "1 bar")], id: \.0) { beats, name in
                            Button(name) { model.edit("Echo Delay", undo: undo) { $0.lanes[lane.rawValue]?.echoBeats = beats } }
                        }
                    }
                    Menu("Feedback") {
                        ForEach([0.3, 0.45, 0.55, 0.7], id: \.self) { fb in
                            Button("\(Int(fb * 100))%") { model.edit("Echo Feedback", undo: undo) { $0.lanes[lane.rawValue]?.feedback = fb } }
                        }
                    }
                }
                Button("Remove Lane", role: .destructive) {
                    model.edit("Remove \(lane.title) Lane", undo: undo) { $0.lanes[lane.rawValue] = nil }
                }
            }
            .menuStyle(.borderlessButton)
            .font(.caption2)
            .fixedSize()
    }

    private func setShape(_ shape: CurveShape, strength: Double) {
        model.edit("Change \(lane.title) Curve", undo: undo) { s in
            guard var l = s.lanes[lane.rawValue] else { return }
            l.shape = shape
            l.strength = strength
            l.regenerate(lane, sequential: !s.sync, beats: s.beats)
            s.lanes[lane.rawValue] = l
        }
    }

    // MARK: Drawing

    private func beats(_ side: Side) -> [Double] { side == .out ? session.outBeats : session.inBeats }
    private func points(_ side: Side) -> [Breakpoint] { side == .out ? settings?.out ?? [] : settings?.inc ?? [] }

    private func y(_ v: Double, _ h: CGFloat) -> CGFloat { pad + CGFloat(1 - v) * (h - 2 * pad) }
    private func value(_ y: CGFloat, _ h: CGFloat) -> Double { Double(1 - (y - pad) / (h - 2 * pad)).clamped(0, 1) }

    private func screen(_ p: Breakpoint, _ side: Side, _ h: CGFloat) -> CGPoint {
        CGPoint(x: geometry.x(geometry.frame(curveX: p.x, beats: beats(side))), y: y(p.y, h))
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let h = size.height
        let g = geometry
        let x0 = g.x(Double(session.outSpan.lowerBound)), x1 = g.x(Double(session.inSpan.upperBound))
        ctx.fill(Path(CGRect(x: x0, y: 0, width: x1 - x0, height: h)), with: .color(.accentColor.opacity(0.06)))
        if lane.neutral > 0 && lane.neutral < 1 {   // filter: mark "open"
            var mid = Path(); mid.move(to: CGPoint(x: g.labelWidth, y: y(0.5, h))); mid.addLine(to: CGPoint(x: size.width, y: y(0.5, h)))
            ctx.stroke(mid, with: .color(.secondary.opacity(0.4)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
        }
        for side in [Side.inc, .out] {
            let pts = points(side)
            guard !pts.isEmpty else { continue }
            let b = beats(side)
            let sx0 = g.x(b.first ?? 0), sx1 = g.x(b.last ?? 0)
            var path = Path()
            path.move(to: CGPoint(x: g.labelWidth, y: y(pts[0].y, h)))
            var px = sx0
            while px <= sx1 {
                let cx = g.curveX(frame: g.frame(px), beats: b)
                path.addLine(to: CGPoint(x: px, y: y(evaluate(pts, at: cx), h)))
                px += 2
            }
            path.addLine(to: CGPoint(x: sx1, y: y(pts[pts.count - 1].y, h)))
            path.addLine(to: CGPoint(x: size.width, y: y(pts[pts.count - 1].y, h)))
            let colour = side == .out ? outColour : inColour
            ctx.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: 2, dash: side == .out ? [] : [6, 4]))
            for p in pts {
                let s = screen(p, side, h)
                ctx.fill(Path(ellipseIn: CGRect(x: s.x - 3.5, y: s.y - 3.5, width: 7, height: 7)), with: .color(colour))
            }
        }
        ctx.fill(Path(CGRect(x: 0, y: 0, width: g.labelWidth, height: h)),
                 with: .color(Color(nsColor: .underPageBackgroundColor)))
    }

    // MARK: Editing

    private func nearestPoint(_ loc: CGPoint, _ h: CGFloat) -> (Side, Int)? {
        var best: (Side, Int, CGFloat)?
        for side in [Side.out, .inc] {
            for (i, p) in points(side).enumerated() {
                let s = screen(p, side, h)
                let d = hypot(s.x - loc.x, s.y - loc.y)
                if d < 8 && d < (best?.2 ?? .infinity) { best = (side, i, d) }
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// Side whose curve passes within 8 px of loc, and the curve x there.
    private func nearestLine(_ loc: CGPoint, _ h: CGFloat) -> (Side, Double)? {
        for side in [Side.out, .inc] {
            let pts = points(side), b = beats(side)
            guard !pts.isEmpty, loc.x >= geometry.x(b.first ?? 0), loc.x <= geometry.x(b.last ?? 0) else { continue }
            let cx = geometry.curveX(frame: geometry.frame(loc.x), beats: b)
            if abs(y(evaluate(pts, at: cx), h) - loc.y) < 8 { return (side, cx) }
        }
        return nil
    }

    private func snap(_ x: Double) -> Double {
        if NSEvent.modifierFlags.contains(.command) { return x }
        let q = Double(spec.beats * 4)
        return (x * q).rounded() / q
    }

    private func mutatePoints(_ side: Side, _ change: (inout [Breakpoint]) -> Void) {
        model.live { s in
            guard var l = s.lanes[lane.rawValue] else { return }
            if side == .out { change(&l.out) } else { change(&l.inc) }
            l.shape = .manual
            s.lanes[lane.rawValue] = l
        }
    }

    private func changed(_ v: DragGesture.Value, height h: CGFloat) {
        guard v.startLocation.x > geometry.labelWidth else { return }
        if target == nil {
            moved = false
            let doubleClick = (NSApp.currentEvent?.clickCount ?? 1) >= 2
            if let (side, i) = nearestPoint(v.startLocation, h) {
                if doubleClick {
                    let count = points(side).count
                    if i > 0 && i < count - 1 { mutatePoints(side) { $0.remove(at: i) }; model.commit("Delete Point", undo: undo) }
                    target = Target.none
                    return
                }
                if NSEvent.modifierFlags.contains(.option), i < points(side).count - 1 {
                    target = .bend(side, i, points(side)[i].bend)
                } else {
                    target = .point(side, i)
                }
            } else if NSEvent.modifierFlags.contains(.option), let (side, cx) = nearestLine(v.startLocation, h),
                      let seg = points(side).lastIndex(where: { $0.x <= cx }) {
                target = .bend(side, seg, points(side)[seg].bend)
            } else {
                target = Target.none
            }
        }
        guard hypot(v.translation.width, v.translation.height) > 1 else { return }
        moved = true
        switch target {
        case let .point(side, i):
            let pts = points(side)
            let isEnd = i == 0 || i == pts.count - 1
            var nx = pts[i].x
            if !isEnd {
                let raw = geometry.curveX(frame: geometry.frame(v.location.x), beats: beats(side))
                let lo = pts[i - 1].x + 1e-4, hi = pts[i + 1].x - 1e-4
                nx = snap(raw).clamped(lo, hi)
            }
            let ny = value(v.location.y, h)
            mutatePoints(side) { $0[i].x = nx; $0[i].y = ny }
        case let .bend(side, i, start):
            let delta = Double(-v.translation.height / 60)
            let pts = points(side)
            let rising = pts[min(i + 1, pts.count - 1)].y > pts[i].y
            mutatePoints(side) { $0[i].bend = (start + (rising ? delta : -delta)).clamped(-1, 1) }
        default:
            break
        }
    }

    private func ended(_ v: DragGesture.Value, height h: CGFloat) {
        defer { target = nil; moved = false }
        guard v.startLocation.x > geometry.labelWidth else { return }
        switch target {
        case .point, .bend:
            if moved { model.commit("Edit Curve", undo: undo) }
        default:
            guard !moved else { return }
            if let (side, cx) = nearestLine(v.startLocation, h) {
                let nx = snap(cx)
                let ny = value(v.startLocation.y, h)
                mutatePoints(side) { pts in
                    guard let at = pts.firstIndex(where: { $0.x > nx }), at > 0, pts[at - 1].x < nx else { return }
                    pts.insert(Breakpoint(nx, ny, bend: pts[at - 1].bend), at: at)
                }
                model.commit("Add Point", undo: undo)
            } else {
                model.seek(to: Int(geometry.frame(v.startLocation.x)))
            }
        }
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 58
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }
}
