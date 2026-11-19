import Foundation
import PregameCore
import SwiftUI

/// State behind the transition editor: a lens on one window of the whole-mix
/// engine (one transport for the timeline and the editor). Curve edits are
/// heard immediately; structural edits go through the document and re-plan
/// the mix. While playing, Follow keeps the editor on the transition the
/// playhead is in or heading into.
@MainActor
final class TransitionEditorModel: ObservableObject {
    @Published var index = 0
    @Published private(set) var transitions: [ResolvedTransition] = []
    @Published private(set) var plans: [TransitionPlan] = []
    /// The spec being edited, including uncommitted drags.
    @Published var draft: TransitionSpec?
    @Published private(set) var session: TransitionSession?
    @Published private(set) var building = false
    @Published private(set) var buildError: String?
    /// Loop the current transition (with its lead bars) on the shared playhead.
    @Published private(set) var loop = false
    /// Follow the playhead to the next transition while playing.
    @Published var follow = true
    /// Mix info of the current transition's outgoing and incoming tracks.
    @Published private(set) var infos: (out: TrackMixInfo, inc: TrackMixInfo)?
    /// Bumped when Follow moves to another transition (drives the slide animation).
    @Published private(set) var followMoves = 0

    weak var document: MixDocument?
    weak var player: MixPlayerModel?
    private var signature = ""
    private var buildTask: Task<Void, Never>?
    private var dragging = false

    var current: ResolvedTransition? { transitions.indices.contains(index) ? transitions[index] : nil }
    var plan: TransitionPlan? { plans.indices.contains(index) ? plans[index] : nil }
    var playing: Bool { player?.playing ?? false }
    var isLocked: Bool { draft?.isLocked ?? false }

    // MARK: Syncing with the document

    func attach(_ document: MixDocument, player: MixPlayerModel) {
        self.document = document
        self.player = player
        refresh()
    }

    /// Re-resolve after any project change (call after the player refreshed its layout).
    func refresh() {
        guard let project = document?.project else { return }
        transitions = project.resolvedTransitions()
        plans = project.plans() ?? []
        if index >= transitions.count { index = max(0, transitions.count - 1) }
        if !dragging { draft = current?.spec }
        rebuildIfNeeded()
    }

    /// The user picked a transition (timeline, pill, arrows): show it and
    /// jump the playhead to its lead-in. Follow carries on from there; only
    /// the pin button stops it. While pinned and playing, it just shows it.
    func select(_ i: Int) {
        guard transitions.indices.contains(i) else { return }
        show(i)
        if playing && !follow { return }
        if let w = player?.layout?.windows[safe: i], let lead = leadInFrame(w) { player?.seek(to: lead) }
    }

    /// A song was selected in the playlist: the playhead goes to where that
    /// song starts in the mix (playing or not). The editor shows the
    /// transition leaving it, unless Follow is showing what's playing.
    func select(track id: UUID) {
        guard let player, let layout = player.layout,
              let deck = layout.decks.first(where: { $0.id == id }) else { return }
        player.seek(to: deck.globalStart)
        player.reveal(deck.globalStart..<deck.globalEnd)
        if playing && follow { return }
        if let i = transitions.firstIndex(where: { $0.info.from == id })
            ?? transitions.firstIndex(where: { $0.info.to == id }) {
            withAnimation(Motion.glide) { show(i) }
        }
    }

    /// ⏮/⏭: the previous/next transition's lead-in, relative to the playhead.
    /// Doesn't pin, so Follow carries on from there.
    func jump(by step: Int) {
        guard let player, let layout = player.layout, !layout.windows.isEmpty else { return }
        let here = Self.transition(at: player.position, in: layout) ?? 0
        var target = here + step
        // ⏮ well inside a transition goes back to its own lead-in first, like a CD player.
        if step < 0, let w = layout.windows[safe: here], let lead = leadInFrame(w), player.position > lead + Int(mixSampleRate) {
            target = here
        }
        target = max(0, min(target, layout.windows.count - 1))
        if loop { setLoop(false) }
        show(target)
        if let w = layout.windows[safe: target], let lead = leadInFrame(w) { player.seek(to: lead) }
    }

    private func show(_ i: Int) {
        guard i != index || session == nil else { return }
        if loop { setLoop(false) }
        index = i
        draft = current?.spec
        rebuildIfNeeded()
    }

    private func leadInFrame(_ w: MixLayout.Window) -> Int? {
        guard let project = document?.project, let layout = player?.layout else { return nil }
        let bars = Double(project.transitionDefaults.previewLeadBars)
        let lead = Int(bars * layout.decks[w.index].grid.barLength)
        return max(w.globalStart - lead, layout.decks[w.index].bodyStart, 0)
    }

    // MARK: Editing

    /// Live, uncommitted change (curve drags). Heard immediately.
    func live(_ change: (inout TransitionSpec) -> Void) {
        guard var d = draft, !d.isLocked else { return }
        dragging = true
        change(&d)
        d.customised = true
        draft = d
        session?.update(spec: d)
    }

    /// Commit the draft to the document (one undo step).
    func commit(_ name: String, undo: UndoManager?) {
        dragging = false
        guard let d = draft, let key = current?.key else { return }
        document?.perform(name, undo: undo) { $0.transitions[key] = d }
    }

    /// Change and commit in one go (buttons, pickers). Ignored while locked.
    func edit(_ name: String, undo: UndoManager?, _ change: (inout TransitionSpec) -> Void) {
        guard var d = draft, !d.isLocked else { return }
        change(&d)
        d.customised = true
        draft = d
        session?.update(spec: d)
        commit(name, undo: undo)
    }

    func applyUserPreset(_ p: UserPreset, undo: UndoManager?) {
        guard let base = draft else { return }
        edit("Apply Preset", undo: undo) { $0 = p.applied(to: base) }
    }

    func applyPreset(_ name: String, undo: UndoManager?) {
        guard let base = draft else { return }
        edit("Apply Preset", undo: undo) { s in
            var next = TransitionConfig.shared.spec(preset: name, base: base)
            next.mixOn = base.mixOn
            next.inDelay = base.inDelay
            s = next
        }
    }

    func resetToAuto(undo: UndoManager?) {
        guard let key = current?.key, !isLocked else { return }
        document?.perform("Reset Transition", undo: undo) { $0.transitions[key] = nil }
    }

    /// Lock (freeze the exact placement) or unlock the current transition.
    func setLocked(_ on: Bool, undo: UndoManager?) {
        guard let key = current?.key else { return }
        document?.perform(on ? "Lock Transition" : "Unlock Transition", undo: undo) { $0.setTransitionLocked(key, on) }
    }

    func setDefaults(_ name: String, undo: UndoManager?, _ change: (inout TransitionDefaults) -> Void) {
        document?.perform(name, undo: undo) { change(&$0.transitionDefaults) }
    }

    /// Rebuild the view even if nothing structural changed (e.g. stems arrived).
    func invalidate() {
        signature = ""
        prefetched.removeAll()
        rebuildIfNeeded()
    }

    // MARK: Session (a view of the mix engine)

    private func rebuildIfNeeded() {
        guard let project = document?.project, let player, let mix = player.mix, let layout = player.layout,
              let t = current, let w = layout.windows[safe: index] else {
            buildTask?.cancel()
            session = nil
            infos = nil
            signature = ""
            return
        }
        let inc = project.included
        if let a = inc.firstIndex(where: { $0.id == t.info.from }), a + 1 < inc.count,
           let oi = player.infos[inc[a].id], let ii = player.infos[inc[a + 1].id] {
            infos = (oi, ii)
        }
        let lead = project.transitionDefaults.previewLeadBars
        let sig = Self.signature(w, layout, lead: lead)
        if sig == signature {
            if let d = draft { session?.update(spec: d) }
            return
        }
        signature = sig
        buildTask?.cancel()
        if let ready = prefetched[sig] {
            // Built ahead while the previous transition played: swap at once.
            prefetched[sig] = nil
            building = false
            buildError = nil
            if let latest = draft { ready.update(spec: latest) }
            withAnimation(Motion.glide) { session = ready }
            if loop { ready.setLoop(0..<ready.length) }
            return
        }
        building = true
        buildError = nil
        let i = index
        buildTask = Task { [weak self] in
            let result: Result<TransitionSession, Error> = await Task.detached(priority: .userInitiated) {
                Result { try TransitionSession(mix: mix, window: i, leadBars: lead) }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.building = false
            switch result {
            case let .success(s):
                if let latest = self.draft { s.update(spec: latest) }
                withAnimation(Motion.glide) { self.session = s }
                if self.loop { s.setLoop(0..<s.length) }
            case let .failure(e):
                self.buildError = (e as? LocalizedError)?.errorDescription
                    ?? "Couldn't prepare this transition (\(e))."
                self.session = nil
            }
        }
    }

    private static func signature(_ w: MixLayout.Window, _ layout: MixLayout, lead: Int) -> String {
        [w.signatureKey, "\(w.globalStart)", "\(layout.decks[w.index].bodyStart)", "\(lead)", "\(w.index)"]
            .joined(separator: "|")
    }

    /// Views of upcoming transitions, built in the background (by signature).
    private var prefetched: [String: TransitionSession] = [:]
    private var prefetching: String?

    /// While following, build the next transition's view ahead of time.
    private func prefetchNext() {
        guard let project = document?.project, let player, let mix = player.mix, let layout = player.layout,
              let w = layout.windows[safe: index + 1] else { return }
        let lead = project.transitionDefaults.previewLeadBars
        let sig = Self.signature(w, layout, lead: lead)
        guard prefetched[sig] == nil, prefetching != sig else { return }
        prefetching = sig
        let i = w.index
        Task { [weak self] in
            let s = await Task.detached(priority: .utility) { try? TransitionSession(mix: mix, window: i, leadBars: lead) }.value
            guard let self else { return }
            self.prefetching = nil
            guard let s else { return }
            // Keep only what is still current.
            self.prefetched = self.prefetched.filter { k, _ in layout.windows.contains { Self.signature($0, layout, lead: lead) == k } }
            self.prefetched[sig] = s
        }
    }

    // MARK: Transport (shared with the timeline)

    func togglePlay() { player?.togglePlay() }
    func play() { player?.play() }
    func pause() { player?.pause() }

    /// Seek to a frame of the current view.
    func seek(to frame: Int) {
        guard let session else { return }
        player?.seek(to: session.globalFrame(frame))
    }

    /// Playhead position in the current view's frames.
    var position: Int {
        guard let session, let player else { return 0 }
        return session.localFrame(player.position)
    }

    func setLoop(_ on: Bool) {
        loop = on
        guard let s = session else { return }
        if on {
            s.setLoop(0..<s.length)
            if let p = player, !s.globalRange.contains(p.position) { p.seek(to: s.globalRange.lowerBound) }
        } else {
            s.setLoop(nil)
        }
    }

    /// Called by the playhead timers: Follow the playhead between transitions.
    func tick() {
        guard let player, player.playing, follow, !loop, let layout = player.layout,
              let target = Self.transition(at: player.position, in: layout) else { return }
        if target != index {
            followMoves += 1
            withAnimation(Motion.glide) { show(target) }
        } else if let w = layout.windows[safe: index], player.position >= w.globalStart {
            prefetchNext()
        }
    }

    /// The transition the playhead is in or heading into: the first whose
    /// window (plus echo tail) hasn't passed yet.
    static func transition(at frame: Int, in layout: MixLayout) -> Int? {
        guard !layout.windows.isEmpty else { return nil }
        let tailBars = Double(TransitionConfig.shared.defaults.echoTailBars)
        for w in layout.windows {
            let tail = w.spec.lane(.echo) != nil ? Int(tailBars * 4 * w.endBeatLength) : 0
            if frame < w.globalEnd + tail { return w.index }
        }
        return layout.windows.count - 1
    }
}
