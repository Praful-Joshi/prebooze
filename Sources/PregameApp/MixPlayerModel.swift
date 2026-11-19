import Foundation
import PregameCore
import SwiftUI

/// Whole-mix playback for the timeline: keeps a MixEngine in step with the
/// project and pre-loads audio (decoding + window stretching) ahead of the
/// playhead while playing.
@MainActor
final class MixPlayerModel: ObservableObject {
    @Published private(set) var layout: MixLayout?
    @Published private(set) var playing = false
    @Published private(set) var loading = false
    /// A span of the mix the timeline should bring to the centre (a song
    /// picked in the playlist); `revealToken` changes with every request.
    private(set) var revealRange: Range<Int>?
    @Published private(set) var revealToken = 0
    func reveal(_ range: Range<Int>) {
        revealRange = range
        revealToken += 1
    }

    /// The song at the playhead (playing or paused).
    @Published private(set) var playingTrack: UUID?
    /// Per included track, for drawing sections and cues.
    @Published private(set) var infos: [UUID: TrackMixInfo] = [:]

    /// Shared with the transition editor (set by the window before use).
    var engine = AudioEngine()
    private(set) var mix: MixEngine?
    private var prefetch: Task<Void, Never>?
    private var layoutTask: Task<Void, Never>?
    weak var document: MixDocument?

    var position: Int { mix?.position ?? 0 }

    func attach(_ document: MixDocument) {
        self.document = document
        refresh()
    }

    /// Rebuild the layout after any project change (cheap: arithmetic only).
    func refresh() {
        guard let project = document?.project else { return }
        guard let (_, layout) = project.mixLayout() else {
            self.layout = nil
            return
        }
        self.layout = layout
        infos = Dictionary((project.mixInfos() ?? []).map { ($0.track.id, $0) }, uniquingKeysWith: { a, _ in a })
        if let mix {
            mix.update(layout: layout)
        } else {
            mix = MixEngine(layout: layout)
        }
    }

    /// Newly separated stems: load them around the playhead.
    func reloadStems() {
        guard let mix, let layout else { return }
        let pos = position
        Task.detached(priority: .utility) {
            try? mix.prepare(max(0, pos - Int(10 * mixSampleRate))..<min(pos + Int(90 * mixSampleRate), layout.length),
                             evictOthers: false)
        }
    }

    // MARK: Transport

    func togglePlay() { playing ? pause() : play() }

    func play(from frame: Int? = nil) {
        guard let mix, let layout else { return }
        if let frame { mix.seek(to: frame) }
        let start = frame ?? mix.position
        loading = true
        prefetch?.cancel()
        prefetch = Task { [weak self] in
            // Load what's needed right now, then keep loading ahead while playing.
            let ready = await Task.detached(priority: .userInitiated) {
                (try? mix.prepare(start..<min(start + Int(20 * mixSampleRate), layout.length))) != nil
            }.value
            guard let self, !Task.isCancelled else { return }
            self.loading = false
            guard ready else { return }
            self.engine.setSource(mix)
            self.engine.ensureRunning()
            mix.play()
            self.playing = true
            while !Task.isCancelled && self.playing {
                let pos = mix.position
                let current = self.layout ?? layout
                await Task.detached(priority: .utility) {
                    try? mix.prepare(max(0, pos - Int(5 * mixSampleRate))..<min(pos + Int(60 * mixSampleRate), current.length))
                }.value
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func pause() {
        mix?.pause()
        prefetch?.cancel()
        playing = false
        loading = false
    }

    func seek(to frame: Int) {
        if playing { play(from: frame) } else { mix?.seek(to: frame) }
    }

    /// Called by the playhead timer.
    func tick() {
        if playing, let mix, !mix.isPlaying || !engine.isCurrent(mix) {
            playing = false
            prefetch?.cancel()
        }
        // The song at the playhead: the latest one to have come in (so a click
        // on a song, which seeks to its start, highlights that song).
        if let layout {
            let pos = position
            let i = layout.decks.lastIndex { $0.globalStart <= pos } ?? 0
            let id = layout.decks[safe: i]?.id
            if id != playingTrack { playingTrack = id }
        }
    }
}
