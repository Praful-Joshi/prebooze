import AppKit
import PregameCore
import SwiftUI

/// The playlist as a compact sidebar: two-line rows (title + key/BPM pills,
/// artist), the transition between two songs drawn on the divider between
/// them (with its lock), and songs left out of the mix in a collapsible
/// section below a divider row. Dragging across that divider includes or
/// excludes; locked transitions drag their whole chain.
struct PlaylistSidebar: View {
    @ObservedObject var document: MixDocument
    @ObservedObject var editor: TransitionEditorModel
    @Binding var selection: Set<ProjectTrack.ID>
    let showInfo: (ProjectTrack) -> Void
    @Binding var alert: String?
    @Environment(\.undoManager) private var undo
    @AppStorage("excludedExpanded") private var excludedExpanded = true
    @State private var confirmExclude: Set<UUID>?

    private var project: MixProject { document.project }

    /// Rows of the list: included songs, the divider, excluded songs.
    enum Item: Hashable, Identifiable {
        case track(UUID), divider
        var id: String { if case let .track(u) = self { u.uuidString } else { "divider" } }
    }

    private var items: [Item] {
        let inc = project.included.map { Item.track($0.id) }
        let exc = project.tracks.filter { !$0.include }.map { Item.track($0.id) }
        if exc.isEmpty { return inc }
        return inc + [.divider] + (excludedExpanded ? exc : [])
    }

    var body: some View {
        let resolved = project.resolvedTransitions()
        let nextFrom = Dictionary(resolved.map { ($0.info.from, $0) }, uniquingKeysWith: { a, _ in a })
        let positions = Dictionary(uniqueKeysWithValues: project.included.enumerated().map { ($1.id, $0 + 1) })
        let byId = Dictionary(uniqueKeysWithValues: project.tracks.map { ($0.id, $0) })
        let playingWindow = editor.playing ? editor.index : nil
        VStack(spacing: 0) {
            if project.tracks.isEmpty {
                EmptyPlaylist()
            } else {
                ScrollViewReader { proxy in
                List(selection: $selection) {
                    ForEach(items) { item in
                        switch item {
                        case let .track(id):
                            if let t = byId[id] {
                                TrackRow(document: document, track: t, position: positions[id],
                                         next: t.include ? nextFrom[id] : nil,
                                         nextIndex: nextFrom[id].flatMap { n in resolved.firstIndex { $0.key == n.key } },
                                         playingWindow: playingWindow,
                                         onLock: { key, on in setLock(key, on) },
                                         onOpenTransition: { editor.select($0) },
                                         menu: { AnyView(menu(for: t)) })
                                    .tag(id)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 6))
                            }
                        case .divider:
                            ExcludedHeader(count: project.tracks.count - project.included.count, expanded: $excludedExpanded)
                                .listRowSeparator(.hidden)
                                .selectionDisabled()
                                .moveDisabled(true)
                        }
                    }
                    .onMove(perform: move)
                }
                .listStyle(.sidebar)
                .onChange(of: selection) {
                    // Keep the selected (or now playing) song in view.
                    guard selection.count == 1, let id = selection.first else { return }
                    withAnimation(Motion.glide) { proxy.scrollTo(Item.track(id).id, anchor: .center) }
                }
                .scrollContentBackground(.hidden)
                .animation(Motion.settle, value: items)
                .contextMenu(forSelectionType: ProjectTrack.ID.self) { ids in
                    if let id = ids.first, let t = byId[id] { menu(for: t, targets: ids) }
                } primaryAction: { ids in
                    if let id = ids.first, let t = byId[id] { showInfo(t) }
                }
                .onDeleteCommand { exclude(selection) }
                .background {
                    Button("") { remove(selection) }.keyboardShortcut(.delete, modifiers: .command).hidden()
                }
                }
            }
            SummaryBar(project: project)
        }
        .confirmationDialog("Unlock and leave out?", isPresented: Binding(get: { confirmExclude != nil },
                                                                            set: { if !$0 { confirmExclude = nil } }),
                            presenting: confirmExclude) { ids in
            Button("Unlock and Leave Out") { exclude(ids, force: true) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("A locked transition joins this song to its neighbour. Leaving it out unlocks that transition.")
        }
    }

    // MARK: Actions

    private func setLock(_ key: String, _ on: Bool) {
        document.perform(on ? "Lock Transition" : "Unlock Transition", undo: undo) { $0.setTransitionLocked(key, on) }
    }

    private func move(_ from: IndexSet, _ to: Int) {
        let list = items
        let moving = Set(from.compactMap { i -> UUID? in if case let .track(id) = list[i] { id } else { nil } })
        guard !moving.isEmpty else { return }
        let dividerAt = list.firstIndex(of: .divider) ?? list.count
        let toExcluded = to > dividerAt
        // The first non-moving track at or after the drop point.
        let target = list[to...].compactMap { item -> UUID? in
            if case let .track(id) = item, !moving.contains(id) { id } else { nil }
        }.first
        let wasIncluded = moving.contains { id in project.tracks.first { $0.id == id }?.include == true }
        if toExcluded && wasIncluded && !project.lockedTransitionKeys(touching: moving).isEmpty {
            confirmExclude = moving
            return
        }
        document.perform(toExcluded ? "Leave Out of Mix" : "Move Tracks", undo: undo) { p in
            let ids = Set(p.withLockedPartners(moving))
            for i in p.tracks.indices where ids.contains(p.tracks[i].id) { p.tracks[i].include = !toExcluded }
            p.moveTracks(moving, before: target)
        }
    }

    private func exclude(_ ids: Set<UUID>, force: Bool = false) {
        guard !ids.isEmpty else { return }
        let locked = project.lockedTransitionKeys(touching: ids)
        if !locked.isEmpty && !force { confirmExclude = ids; return }
        document.perform("Leave Out of Mix", undo: undo) { p in
            for k in locked { p.setTransitionLocked(k, false) }
            for i in p.tracks.indices where ids.contains(p.tracks[i].id) { p.tracks[i].include = false }
            // Left-out songs go to the bottom.
            let out = p.tracks.filter { ids.contains($0.id) }
            p.tracks.removeAll { ids.contains($0.id) }
            p.tracks += out
        }
    }

    private func include(_ ids: Set<UUID>) {
        document.perform("Add to Mix", undo: undo) { p in
            for i in p.tracks.indices where ids.contains(p.tracks[i].id) { p.tracks[i].include = true }
            let back = p.tracks.filter { ids.contains($0.id) }
            p.tracks.removeAll { ids.contains($0.id) }
            p.tracks.insert(contentsOf: back, at: p.tracks.firstIndex { !$0.include } ?? p.tracks.endIndex)
        }
    }

    private func remove(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        document.perform("Remove Tracks", undo: undo) { p in
            p.tracks.removeAll { ids.contains($0.id) }
            if let f = p.settings.lockFirst, ids.contains(f) { p.settings.lockFirst = nil }
            if let l = p.settings.lockLast, ids.contains(l) { p.settings.lockLast = nil }
        }
        selection.subtract(ids)
    }

    @ViewBuilder private func menu(for t: ProjectTrack, targets given: Set<UUID>? = nil) -> some View {
        let targets = given ?? (selection.contains(t.id) ? selection : [t.id])
        Button("Get Info") { showInfo(t) }.keyboardShortcut("i")
        Menu("Key Shift") {
            ForEach(Array((-6...6).reversed()), id: \.self) { st in
                Button {
                    document.perform("Key Shift", undo: undo) { p in
                        for id in targets { if let i = p.index(of: id) { p.tracks[i].keyShift = st } }
                    }
                } label: {
                    let label = st == 0 ? "None" : String(format: "%+d semitone%@", st, abs(st) == 1 ? "" : "s")
                    let key = t.baseKey.map { " → \($0.transposed(st))" } ?? ""
                    if t.keyShift == st { Label(label + key, systemImage: "checkmark") } else { Text(label + key) }
                }
            }
        }
        Button("Revert Key/BPM to Detected") {
            document.perform("Revert Overrides", undo: undo) { p in
                for id in targets { if let i = p.index(of: id) { p.tracks[i].keyOverride = nil; p.tracks[i].bpmOverride = nil } }
            }
        }.disabled(!targets.contains { id in project.tracks.first { $0.id == id }?.isOverridden == true })
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([t.url]) }
        Button(targets.count > 1 ? "Export \(targets.count) STEM Files for Mixxx…" : "Export STEM File for Mixxx…") {
            Panels.exportStemFiles(project.tracks.filter { targets.contains($0.id) })
        }
        Divider()
        if t.include {
            Button("Leave Out of Mix") { exclude(targets) }.keyboardShortcut(.delete, modifiers: [])
        } else {
            Button("Add Back to Mix") { include(targets) }
        }
        Button("Remove from Project", role: .destructive) { remove(targets) }.keyboardShortcut(.delete, modifiers: .command)
    }
}

// MARK: - Row

struct TrackRow: View {
    @ObservedObject var document: MixDocument
    let track: ProjectTrack
    let position: Int?
    let next: ResolvedTransition?
    let nextIndex: Int?
    let playingWindow: Int?
    let onLock: (String, Bool) -> Void
    let onOpenTransition: (Int) -> Void
    let menu: () -> AnyView
    @State private var hover = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: Space.s) {
                ZStack {
                    Text(position.map(String.init) ?? "–").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        .opacity(hover ? 0 : 1)
                    Image(systemName: "line.3.horizontal").font(.caption).foregroundStyle(.secondary)
                        .opacity(hover ? 1 : 0)
                        .help("Drag to reorder")
                }
                .frame(width: 18)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(track.title).font(.callout.weight(.medium)).lineLimit(1)
                    Text(track.artist.isEmpty ? " " : track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .opacity(track.include ? 1 : 0.5)
                Spacer(minLength: 2)
                Menu { menu() } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .opacity(hover ? 1 : 0)
                KeyPill(document: document, track: track)
                BpmPill(document: document, track: track)
            }
            .padding(.vertical, Space.s)
            if let next, let nextIndex {
                TransitionPill(transition: next, index: nextIndex, playing: playingWindow == nextIndex,
                               onLock: onLock, onOpen: onOpenTransition)
            }
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Motion.hover) { hover = h } }
    }
}

/// The transition to the next song, sitting on the divider between the two rows.
struct TransitionPill: View {
    let transition: ResolvedTransition
    let index: Int
    let playing: Bool
    let onLock: (String, Bool) -> Void
    let onOpen: (Int) -> Void
    @State private var hover = false
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let locked = transition.spec.isLocked
        HStack(spacing: Space.s) {
            Rectangle().fill(.separator).frame(height: 1)
            HStack(spacing: Space.xs) {
                Circle().fill(Ink.legacyMatch(transition.info.label.colour)).frame(width: 7, height: 7)
                    .scaleEffect(pulse ? 1.5 : 1)
                Text(transition.info.label.label).lineLimit(1)
                Text("· \(transition.spec.bars)").foregroundStyle(.tertiary)
                if locked || hover {
                    Button { onLock(transition.key, !locked) } label: {
                        Image(systemName: locked ? "lock.fill" : "lock.open")
                            .foregroundStyle(locked ? Ink.accent : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(locked ? "Locked: placement frozen and these two songs stay together. Click to unlock."
                                 : "Lock this transition: freeze it as it is and keep these two songs together")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .font(.caption2)
            .fixedSize()
            .padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
            .background(Capsule().fill(.background.secondary))
            .overlay(Capsule().strokeBorder(locked ? Ink.accent.opacity(0.6) : Color.clear))
            .scaleEffect(hover ? 1.04 : 1)
            .onTapGesture { onOpen(index) }
            .help("\(transition.info.label.label) · \(transition.spec.preset), \(transition.spec.bars) bars. Click to edit.")
            Rectangle().fill(.separator).frame(height: 1)
        }
        .padding(.leading, Space.xxl)
        .frame(height: 16)
        .onHover { h in withAnimation(Motion.pop) { hover = h } }
        .onChange(of: playing, initial: true) { _, on in
            guard !reduceMotion else { return }
            if on, let breathe = Motion.breathe {
                withAnimation(breathe) { pulse = true }
            } else {
                withAnimation(Motion.fade) { pulse = false }
            }
        }
    }
}

extension CamelotKey {
    /// Camelot wheel colour (number → hue; major keys a little lighter).
    var wheelColour: Color { Ink.key(self) }
}

// MARK: - Key & BPM pills

struct KeyPill: View {
    @ObservedObject var document: MixDocument
    let track: ProjectTrack
    @State private var open = false

    var body: some View {
        // A key shift keeps the normal pill and adds "↕ +2"; colour is kept for problems and overrides.
        let tint: Color? = track.key == nil ? Ink.missing : track.keyOverride != nil ? Ink.overridden : nil
        let shift = track.keyShift == 0 ? "" : String(format: " ↕ %+d", track.keyShift)
        Button { open = true } label: {
            HStack(spacing: 0) {
                Rectangle().fill(Ink.key(track.key)).frame(width: 3)
                Text((track.key?.description ?? "–") + shift).font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, Space.s)
            }
            .frame(minWidth: 36, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill((tint ?? .secondary).opacity(tint == nil ? 0.12 : 0.3)))
            .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(track.keyShift != 0 ? String(format: "Key-shifted %+d from %@. Click to change.", track.keyShift,
                                           track.baseKey?.description ?? "–")
              : track.keyOverride != nil ? "Overridden (detected \(track.detectedKey?.description ?? "–")). Click to change."
              : "Click to override the key or shift it")
        .popover(isPresented: $open, arrowEdge: .bottom) { KeyEditor(document: document, track: track, open: $open) }
    }
}

struct KeyEditor: View {
    @ObservedObject var document: MixDocument
    let track: ProjectTrack
    @Binding var open: Bool
    @Environment(\.undoManager) private var undo
    @State private var text = ""
    @State private var bad = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text("Key").font(.headline)
            TextField("e.g. 8A, Am, 1m", text: $text)
                .textFieldStyle(.roundedBorder).frame(width: 170)
                .onSubmit(commit)
                .modifier(Shake(trigger: bad))
            Text("Detected \(track.detectedKey?.description ?? "–")" + (track.tagKey.map { " · tag \($0)" } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Stepper(value: Binding(get: { track.keyShift }, set: { v in
                document.perform("Key Shift", undo: undo) { p in if let i = p.index(of: track.id) { p.tracks[i].keyShift = v } }
            }), in: -6...6) {
                Text("Shift \(track.keyShift == 0 ? "0" : String(format: "%+d", track.keyShift)) st"
                     + (track.key.map { " → \($0)" } ?? ""))
            }
            HStack {
                Button("Revert") {
                    document.perform("Revert Key", undo: undo) { p in
                        if let i = p.index(of: track.id) { p.tracks[i].keyOverride = nil; p.tracks[i].keyShift = 0 }
                    }
                    open = false
                }
                .disabled(track.keyOverride == nil && track.keyShift == 0)
                Spacer()
                Button("Done") { commit() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xl)
        .onAppear { text = track.baseKey?.description ?? "" }
        .onExitCommand { open = false }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parsed = parseKey(trimmed)
        if !trimmed.isEmpty && parsed == nil { bad.toggle(); NSSound.beep(); return }
        let newOverride = parsed == track.detectedKey ? nil : parsed
        if newOverride != track.keyOverride {
            document.perform("Edit Key", undo: undo) { p in if let i = p.index(of: track.id) { p.tracks[i].keyOverride = newOverride } }
        }
        open = false
    }
}

struct BpmPill: View {
    @ObservedObject var document: MixDocument
    let track: ProjectTrack
    @State private var open = false

    var body: some View {
        let tint: Color? = (track.bpm ?? 0) <= 0 ? Ink.missing : track.bpmOverride != nil ? Ink.overridden : nil
        Button { open = true } label: {
            Text(track.bpm.map { String(format: "%g", ($0 * 10).rounded() / 10) } ?? "–")
                .font(.caption.monospacedDigit())
                .frame(minWidth: 34, minHeight: 18)
                .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill((tint ?? .secondary).opacity(tint == nil ? 0.08 : 0.3)))
        }
        .buttonStyle(.plain)
        .help(track.bpmOverride != nil ? "Overridden (detected \(fmt(track.detectedBpm))). Click to change."
                                       : "\(fmt(track.bpm)) BPM. Click to override.")
        .popover(isPresented: $open, arrowEdge: .bottom) { BpmEditor(document: document, track: track, open: $open) }
    }

    private func fmt(_ v: Double?) -> String { v.map { String(format: "%g", ($0 * 100).rounded() / 100) } ?? "–" }
}

struct BpmEditor: View {
    @ObservedObject var document: MixDocument
    let track: ProjectTrack
    @Binding var open: Bool
    @Environment(\.undoManager) private var undo
    @State private var text = ""
    @State private var bad = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text("BPM").font(.headline)
            TextField("BPM", text: $text).textFieldStyle(.roundedBorder).frame(width: 120)
                .onSubmit(commit).modifier(Shake(trigger: bad))
            HStack(spacing: Space.s) {
                Button("½×") { scale(0.5) }
                Button("2×") { scale(2) }
            }
            .controlSize(.small)
            Text("Detected \(track.detectedBpm.map { String(format: "%g", ($0 * 100).rounded() / 100) } ?? "–")")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Revert") {
                    document.perform("Revert BPM", undo: undo) { p in if let i = p.index(of: track.id) { p.tracks[i].bpmOverride = nil } }
                    open = false
                }
                .disabled(track.bpmOverride == nil)
                Spacer()
                Button("Done") { commit() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xl)
        .onAppear { text = track.bpm.map { String(format: "%g", ($0 * 100).rounded() / 100) } ?? "" }
        .onExitCommand { open = false }
    }

    private func scale(_ k: Double) {
        if let v = Double(text.replacingOccurrences(of: ",", with: ".")) { text = String(format: "%g", (v * k * 100).rounded() / 100) }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let value = Double(trimmed)
        if !trimmed.isEmpty && (value == nil || value! <= 0 || value! > 400) { bad.toggle(); NSSound.beep(); return }
        let newOverride: Double? = value.flatMap { v in
            if let d = track.detectedBpm, abs(d - v) < 0.005 { return nil }
            return v
        }
        if newOverride != track.bpmOverride {
            document.perform("Edit BPM", undo: undo) { p in if let i = p.index(of: track.id) { p.tracks[i].bpmOverride = newOverride } }
        }
        open = false
    }
}

// MARK: - Bits

struct ExcludedHeader: View {
    let count: Int
    @Binding var expanded: Bool

    var body: some View {
        Button { withAnimation(Motion.settle) { expanded.toggle() } } label: {
            HStack(spacing: Space.s) {
                Image(systemName: "chevron.right").font(.caption2.bold())
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text("Not in mix").font(.caption.weight(.semibold))
                Text("\(count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.horizontal, Space.s).background(Capsule().fill(.quaternary))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.top, Space.l).padding(.bottom, Space.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Songs left out of the mix. Drag songs here to leave them out, or back up to include them.")
    }
}

struct SummaryBar: View {
    let project: MixProject
    var body: some View {
        let s = project.summary()
        HStack(spacing: Space.m) {
            Text("\(project.included.count) songs")
            Spacer()
            ForEach([(TransitionColour.green, s.green), (TransitionColour.yellow, s.yellow), (TransitionColour.blue, s.blue),
                     (TransitionColour.red, s.red)], id: \.0) { c, n in
                HStack(spacing: Space.xs) { Circle().fill(Ink.legacyMatch(c)).frame(width: 6, height: 6); Text("\(n)") }
            }
            if !project.problems.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Ink.error)
                    .help("\(project.problems.count) songs lack a key or BPM")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, Space.l).padding(.vertical, Space.s)
        .help(String(format: "Cost %.1f · average BPM gap %.1f", s.totalCost, s.avgBpmGap))
    }
}

struct EmptyPlaylist: View {
    var body: some View {
        VStack(spacing: Space.l) {
            Image(systemName: "music.note.list").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Add a folder of tracks").font(.title3)
            Text("File › Add Folder… (⇧⌘O)\nKey, BPM and beats are analysed automatically.")
                .multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A short horizontal shake each time `trigger` changes (skipped with Reduce Motion).
struct Shake: ViewModifier {
    let trigger: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, x in
            view.offset(x: reduceMotion ? 0 : x)
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(-6, duration: 0.05)
                LinearKeyframe(6, duration: 0.08)
                LinearKeyframe(-4, duration: 0.08)
                LinearKeyframe(0, duration: 0.06)
            }
        }
    }
}
