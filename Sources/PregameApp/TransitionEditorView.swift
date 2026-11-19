import AppKit
import PregameCore
import SwiftUI

/// The transition editor: a two-line smart bar (title + actions, presets +
/// value chips that only appear when they matter) over the canvas. Playback
/// is the shared mix transport (window toolbar).
struct TransitionEditorView: View {
    @ObservedObject var document: MixDocument
    @ObservedObject var model: TransitionEditorModel
    @ObservedObject var player: MixPlayerModel
    @Environment(\.undoManager) private var undo
    @State private var lockedNudge = false
    @ObservedObject private var stems = StemController.shared
    @State private var userPresets = PresetStore.shared.presets
    @State private var savingPreset = false
    @State private var presetName = ""

    var body: some View {
        VStack(spacing: 0) {
            if model.transitions.isEmpty {
                placeholder("Add at least two analysed tracks to edit transitions.")
            } else if let t = model.current, let spec = model.draft {
                titleLine(t, spec)
                chipLine(spec)
                Divider()
                ZStack {
                    if let session = model.session {
                        EditorCanvas(model: model, session: session, spec: spec)
                            .id(session.windowIndex)
                            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                    removal: .move(edge: .leading).combined(with: .opacity)))
                            .modifier(Shake(trigger: lockedNudge))
                            .overlay { if spec.isLocked { lockedShield } }
                    } else if let error = model.buildError {
                        placeholder(error)
                    } else {
                        placeholder(model.plans.isEmpty ? "Waiting for analysis…" : "Preparing transition…")
                    }
                    if model.building && model.session != nil {
                        ProgressView().controlSize(.small).padding(Space.m)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
                .clipped()
            }
        }
        .background(Ink.canvas)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// While locked the canvas only listens enough to say why nothing moves.
    private var lockedShield: some View {
        Ink.accent.opacity(0.04)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2).onEnded { _ in lockedNudge.toggle() })
            .onTapGesture { lockedNudge.toggle() }
            .overlay(alignment: .top) {
                Label("Locked. Click 🔒 above to edit.", systemImage: "lock.fill")
                    .font(.caption).padding(.horizontal, Space.l).padding(.vertical, Space.xs)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, Space.s)
                    .allowsHitTesting(false)
            }
    }

    // MARK: Line 1: title and actions

    private func titleLine(_ t: ResolvedTransition, _ spec: TransitionSpec) -> some View {
        let byId = Dictionary(uniqueKeysWithValues: document.project.tracks.map { ($0.id, $0) })
        let a = byId[t.info.from], b = byId[t.info.to]
        return HStack(spacing: Space.m) {
            HStack(spacing: 0) {
                Button { model.select(model.index - 1) } label: { Image(systemName: "chevron.left").frame(width: 18) }
                    .disabled(model.index == 0).keyboardShortcut(.leftArrow, modifiers: .option)
                    .help("Previous transition (⌥←)")
                Button { model.select(model.index + 1) } label: { Image(systemName: "chevron.right").frame(width: 18) }
                    .disabled(model.index >= model.transitions.count - 1).keyboardShortcut(.rightArrow, modifiers: .option)
                    .help("Next transition (⌥→)")
            }
            .buttonStyle(.borderless)
            Text("\(model.index + 1)").font(.caption.monospacedDigit().bold()).foregroundStyle(.secondary)
            deckTitle(a)
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
            deckTitle(b)
            HStack(spacing: Space.xs) {
                Circle().fill(Ink.legacyMatch(t.info.label.colour)).frame(width: 7, height: 7)
                Text(t.info.label.label)
            }
            .font(.caption).padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
            .background(Capsule().fill(.quaternary))
            .help("Auto: \(t.reason)")
            Spacer(minLength: 6)
            if let plan = model.plan, !plan.warnings.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Ink.warning)
                    .help(plan.warnings.joined(separator: "\n"))
            }
            if !spec.isLocked, let fix = document.project.suggestKeyShift(forTransition: model.index) {
                Button {
                    document.perform("Key Shift", undo: undo) { p in
                        if let i = p.index(of: fix.track) { p.tracks[i].keyShift = fix.shift }
                    }
                } label: {
                    Label(String(format: "Fix key %@ %+d", fix.track == t.info.from ? "Out" : "In", fix.shift),
                          systemImage: "tuningfork")
                }
                .controlSize(.small).fixedSize()
                .help(fix.summary + ": this transition becomes \(fix.label.label)"
                      + (fix.other.map { "; that song's other transition becomes \($0.label)" } ?? "")
                      + ". Pitch-shifts the song. Undo with ⌘Z.")
                .transition(.scale.combined(with: .opacity))
            }
            if spec.customised && !spec.isLocked {
                Button("Reset") { model.resetToAuto(undo: undo) }.controlSize(.small)
                    .help("Back to the automatic preset")
            }
            Button { model.setLocked(!spec.isLocked, undo: undo) } label: {
                Image(systemName: spec.isLocked ? "lock.fill" : "lock.open")
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(spec.isLocked ? Ink.accent : .secondary)
            }
            .buttonStyle(.borderless)
            .help(spec.isLocked ? "Locked: placement frozen, songs kept together. Click to unlock."
                                : "Lock: freeze this transition as it is and keep these two songs together")
        }
        .animation(Motion.fade, value: spec)
        .padding(.horizontal, Space.l).padding(.top, Space.s).padding(.bottom, Space.xs)
    }

    private func deckTitle(_ t: ProjectTrack?) -> some View {
        HStack(spacing: Space.xs) {
            Text(t?.title ?? "?").font(.headline).lineLimit(1)
            if let k = t?.key {
                Text(k.description).font(.caption2.monospacedDigit().bold())
                    .padding(.horizontal, Space.xs).padding(.vertical, Space.xxs)
                    .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(k.wheelColour.opacity(0.35)))
            }
        }
        .help([t?.artist, t?.bpm.map { String(format: "%g BPM", ($0 * 100).rounded() / 100) },
               (t?.keyShift ?? 0) != 0 ? String(format: "key shift %+d", t!.keyShift) : nil]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
    }

    // MARK: Line 2: presets and chips

    private func chipLine(_ spec: TransitionSpec) -> some View {
        let project = document.project
        let byId = Dictionary(uniqueKeysWithValues: project.tracks.map { ($0.id, $0) })
        let a = model.current.flatMap { byId[$0.info.from] }, b = model.current.flatMap { byId[$0.info.to] }
        return HStack(spacing: Space.m) {
            PresetSegments(selected: hasManual(spec) ? nil : spec.preset) { model.applyPreset($0, undo: undo) }
            myPresetsMenu(spec)
            Chip(title: "\(spec.bars) bar\(spec.bars == 1 ? "" : "s")", help: "Length (scroll to change)",
                 step: { d in stepBars(spec, d) }) {
                ForEach(Array(Set(barChoices + [spec.bars])).sorted(), id: \.self) { v in
                    Button("\(v) bars") { model.edit("Change Length", undo: undo) { $0.bars = v; $0.regenerateLanes() } }
                }
            }
            Chip(title: spec.sync ? (spec.tempo == .full ? "Sync" : "Sync ½") : "No sync",
                 help: "Tempo: glide across the whole window, the second half, or play both at their own tempo") {
                Button("Sync (glide whole window)") { setTempo("full") }
                Button("Sync second half") { setTempo("second_half") }
                Button("No sync") { setTempo("off") }
            }
            mixOnChip(spec)
            if (spec.inDelay ?? 0) > 0 {
                Chip(title: String(format: "In +%g beat%@", model.plan?.inDelay ?? spec.inDelay!, (spec.inDelay ?? 0) == 1 ? "" : "s"),
                     help: "The incoming song starts this many beats into the window (drag the incoming box's left edge, scroll here)",
                     step: { d in model.edit("Delay Incoming", undo: undo) { $0.inDelay = max(0, ($0.inDelay ?? 0) + Double(d)) } }) {
                    Button("No delay") { model.edit("Delay Incoming", undo: undo) { $0.inDelay = nil } }
                    ForEach([1, 2, 4, 8, 16], id: \.self) { n in
                        Button("\(n) beats") { model.edit("Delay Incoming", undo: undo) { $0.inDelay = Double(n) } }
                    }
                }
                .transition(.scale.combined(with: .opacity))
            }
            if let a, a.outroLoop != nil { loopChip("Outro loop", a, \.outroLoop) }
            if let b, b.introLoop != nil { loopChip("Intro loop", b, \.introLoop) }
            if (a?.outroLoop == nil || b?.introLoop == nil), let a, let b {
                Menu {
                    if a.outroLoop == nil { loopItems("Outro loop · \(a.title)", a, \.outroLoop) }
                    if b.introLoop == nil { loopItems("Intro loop · \(b.title)", b, \.introLoop) }
                    if (spec.inDelay ?? 0) == 0 {
                        Divider()
                        Menu("Delay incoming") {
                            ForEach([1, 2, 4, 8, 16], id: \.self) { n in
                                Button("\(n) beats") { model.edit("Delay Incoming", undo: undo) { $0.inDelay = Double(n) } }
                            }
                        }
                    }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Add a loop or delay the incoming song")
            }
            if LaneKind.stems.contains(where: { spec.lane($0) != nil }) { stemStatus(a, b) }
            Spacer()
        }
        .animation(Motion.snap, value: spec)
        .disabled(spec.isLocked)
        .onReceive(NotificationCenter.default.publisher(for: PresetStore.changed)) { _ in userPresets = PresetStore.shared.presets }
        .alert("Save as Preset", isPresented: $savingPreset) {
            TextField("Name", text: $presetName)
            Button("Save") {
                let name = presetName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, let d = model.draft { PresetStore.shared.save(name: name, spec: d) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves this transition's lanes, length and sync for every project.")
        }
        .controlSize(.small)
        .padding(.horizontal, Space.l).padding(.bottom, Space.s)
    }

    private func myPresetsMenu(_ spec: TransitionSpec) -> some View {
        Menu {
            if userPresets.isEmpty { Text("No saved presets yet") }
            ForEach(userPresets) { p in
                Button { model.applyUserPreset(p, undo: undo) } label: {
                    if p.name == spec.preset { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                }
            }
            Divider()
            Button("Save Current as Preset…") {
                presetName = spec.preset == TransitionConfig.shared.preset(spec.preset)?.name ? "" : spec.preset
                savingPreset = true
            }
            if !userPresets.isEmpty {
                Menu("Delete") {
                    ForEach(userPresets) { p in Button(p.name, role: .destructive) { PresetStore.shared.delete(p.id) } }
                }
            }
        } label: {
            Image(systemName: userPresets.contains { $0.name == spec.preset } ? "star.fill" : "star")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("My presets: save this transition's sound and reuse it anywhere")
    }

    /// Whether both songs' stems are ready (stem lanes play the full track until then).
    @ViewBuilder private func stemStatus(_ a: ProjectTrack?, _ b: ProjectTrack?) -> some View {
        let states = [a, b].map { stems.state($0?.contentHash) }
        let failed = states.compactMap { if case let .failed(m) = $0 { m } else { nil } }.first
        let working = states.compactMap { if case let .separating(p) = $0 { p } else { nil } }.first
        Group {
            if states.allSatisfy({ $0 == .ready }) {
                Label("Stems", systemImage: "checkmark.circle.fill").foregroundStyle(Ink.success)
                    .help("Both songs are separated into drums, bass, melody and vocals")
            } else if let failed {
                Button { [a, b].compactMap { $0?.contentHash }.forEach(stems.retry); stems.request([a, b].compactMap { $0 }, urgent: true) } label: {
                    Label("Stems failed: retry", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Ink.warning)
                }
                .buttonStyle(.borderless).help(failed)
            } else {
                HStack(spacing: Space.s) {
                    ProgressView(value: working ?? 0).progressViewStyle(.circular).controlSize(.mini)
                    Text(stems.preparingModel ? "Preparing model…"
                         : working.map { String(format: "Separating stems %d%%", Int($0 * 100)) } ?? "Stems queued")
                }
                .foregroundStyle(.secondary)
                .help("Stem lanes play the whole track until the stems are ready (about 20 s per song)")
            }
        }
        .font(.caption)
        .transition(.opacity)
    }

    private func setTempo(_ v: String) {
        model.edit("Change Tempo", undo: undo) { s in
            if v == "off" { s.sync = false } else { s.sync = true; s.tempo = TempoMode(rawValue: v) ?? .full }
            s.regenerateLanes()
        }
    }

    private func stepBars(_ spec: TransitionSpec, _ d: Int) {
        let choices = barChoices
        let i = choices.firstIndex { $0 >= spec.bars } ?? choices.count - 1
        let v = choices[max(0, min(choices.count - 1, i + d))]
        guard v != spec.bars else { return }
        model.edit("Change Length", undo: undo) { $0.bars = v; $0.regenerateLanes() }
    }

    private func mixOnChip(_ spec: TransitionSpec) -> some View {
        let defaultMode = document.project.transitionDefaults.mixOn
        let used = model.plan?.mode
        let title = (spec.mixOn ?? defaultMode).title + (used != nil && used != (spec.mixOn ?? defaultMode) ? " → \(used!.title)" : "")
        return Chip(title: title, help: "Where the transition sits on both songs" + (spec.mixOn == nil ? " (project default)" : ""),
                    accent: spec.mixOn != nil) {
            Button { model.edit("Change Mix-on", undo: undo) { $0.mixOn = nil; $0.outNudge = 0; $0.inNudge = 0 } } label: {
                Text("Default (\(defaultMode.title))")
            }
            Divider()
            ForEach(MixOnMode.allCases, id: \.self) { m in
                Button(m.title) { model.edit("Change Mix-on", undo: undo) { $0.mixOn = m; $0.outNudge = 0; $0.inNudge = 0 } }
            }
            Divider()
            Menu("Project Default") {
                ForEach(MixOnMode.allCases, id: \.self) { m in
                    Button { model.setDefaults("Change Default Mix-on", undo: undo) { $0.mixOn = m } } label: {
                        if m == defaultMode { Label(m.title, systemImage: "checkmark") } else { Text(m.title) }
                    }
                }
            }
        }
    }

    private func loopChip(_ title: String, _ t: ProjectTrack, _ path: WritableKeyPath<ProjectTrack, TrackLoop?>) -> some View {
        let loop = t[keyPath: path]!
        return Chip(title: "\(title) \(loop.bars)×\(loop.repeats + 1)",
                    help: path == \ProjectTrack.outroLoop ? "Repeats the start of \(t.title)'s outro (scroll to change repeats)"
                                                          : "Repeats the first bars of \(t.title)'s intro (scroll to change repeats)",
                    step: { d in setLoop(title, t, path, TrackLoop(bars: loop.bars, repeats: max(1, min(8, loop.repeats + d)))) }) {
            loopItems(title, t, path)
        }
        .transition(.scale.combined(with: .opacity))
    }

    @ViewBuilder private func loopItems(_ title: String, _ t: ProjectTrack, _ path: WritableKeyPath<ProjectTrack, TrackLoop?>) -> some View {
        Menu(title) {
            Button("Off") { setLoop(title, t, path, nil) }
            Divider()
            ForEach(TrackLoop.barChoices, id: \.self) { bars in
                Menu("\(bars) bar\(bars == 1 ? "" : "s")") {
                    ForEach(1...8, id: \.self) { r in
                        Button("Play \(r + 1)× (+\(bars * r) bars)") { setLoop(title, t, path, TrackLoop(bars: bars, repeats: r)) }
                    }
                }
            }
        }
    }

    private func setLoop(_ title: String, _ t: ProjectTrack, _ path: WritableKeyPath<ProjectTrack, TrackLoop?>, _ v: TrackLoop?) {
        document.perform(title, undo: undo) { p in if let i = p.index(of: t.id) { p.tracks[i][keyPath: path] = v } }
    }

    private func hasManual(_ spec: TransitionSpec) -> Bool { spec.lanes.values.contains { $0.shape == .manual } }
}

// MARK: - Smart bar parts

/// Presets as one segmented capsule; ⌥1–⌥5.
struct PresetSegments: View {
    let selected: String?
    let apply: (String) -> Void
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(TransitionConfig.shared.presets.enumerated()), id: \.offset) { i, p in
                Button { apply(p.name) } label: {
                    Text(p.name).font(.caption.weight(selected == p.name ? .semibold : .regular))
                        .padding(.horizontal, Space.m).padding(.vertical, Space.xs)
                        .background {
                            if selected == p.name {
                                Capsule().fill(Ink.accent).matchedGeometryEffect(id: "sel", in: ns)
                            }
                        }
                        .foregroundStyle(selected == p.name ? Ink.onAccent : .primary)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .option)
                .help("\(p.name) (⌥\(i + 1))")
            }
        }
        .padding(Space.xxs)
        .background(Capsule().fill(.quaternary))
        .animation(Motion.snap, value: selected)
    }
}

/// A compact value chip: shows its value, clicks open a menu, scrolling over
/// it steps the value (when `step` is given). Lifts slightly on hover.
struct Chip<Content: View>: View {
    let title: String
    let help: String
    var accent = false
    var step: ((Int) -> Void)? = nil
    @ViewBuilder let content: () -> Content
    @State private var hover = false

    var body: some View {
        Menu { content() } label: {
            Text(title).font(.caption).lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .tint(accent ? Ink.accent : nil)
        .fixedSize()
        .scaleEffect(hover ? 1.04 : 1)
        .shadow(color: Ink.shadow.opacity(hover ? 0.2 : 0), radius: 3, y: 1)
        .onHover { h in withAnimation(Motion.pop) { hover = h } }
        .background(ScrollStepper(active: hover && step != nil) { step?($0) })
        .help(help)
    }
}

/// Turns scroll-wheel movement over a hovered control into ±1 steps.
struct ScrollStepper: NSViewRepresentable {
    let active: Bool
    let step: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let c = context.coordinator
        c.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            guard c.active else { return e }
            c.accumulated += e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 0.1 : 1)
            while abs(c.accumulated) >= 1 {
                let d = c.accumulated > 0 ? 1 : -1
                c.accumulated -= CGFloat(d)
                c.step(d)
            }
            return nil
        }
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.active = active
        context.coordinator.step = step
        if !active { context.coordinator.accumulated = 0 }
    }

    func makeCoordinator() -> Coordinator { Coordinator(step: step) }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let m = coordinator.monitor { NSEvent.removeMonitor(m) }
    }

    final class Coordinator {
        var active = false
        var step: (Int) -> Void
        var accumulated: CGFloat = 0
        var monitor: Any?
        init(step: @escaping (Int) -> Void) { self.step = step }
    }
}
