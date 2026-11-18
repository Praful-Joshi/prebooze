import AVFoundation
import HarmonizerCore
import SwiftUI

/// Track info sheet: facts, plus the editors for what the mix relies on —
/// song structure (drag boundaries, relabel), bar 1, hot cues and key shift.
/// Structure, bar 1 and cues are stored with the file's analysis (every
/// project sees them); key shift belongs to this project.
struct TrackDetail: View {
    @ObservedObject var document: MixDocument
    let trackID: UUID
    @Environment(\.undoManager) private var undo
    @State private var info: TrackMixInfo?
    @State private var wave: WaveformSummary?
    @StateObject private var preview = FilePreview()

    private var track: ProjectTrack? { document.project.tracks.first { $0.id == trackID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let track {
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title).font(.title3.bold()).lineLimit(2)
                    Text(track.artist).foregroundStyle(.secondary)
                }
                if let info, let wave {
                    StructureEditor(info: info, wave: wave, preview: preview, edit: edit)
                        .frame(height: 150)
                    controls(track, info)
                    cueRow(info)
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary).frame(height: 150)
                        .overlay(Text("Analysing…").foregroundStyle(.secondary))
                }
                facts(track)
            }
        }
        .onAppear(perform: reload)
        .onDisappear { preview.stop() }
        .onChange(of: track) { reload() }
        .onReceive(NotificationCenter.default.publisher(for: AnalysisCache.editsChanged)) { _ in reload() }
    }

    private func reload() {
        guard let track else { return }
        info = AnalysisCache.shared.mixInfo(track)
        if wave == nil, let h = track.contentHash { wave = AnalysisCache.shared.waveform(h) }
        if preview.url != track.url { preview.load(track.url) }
    }

    /// Change this file's edits (undoable).
    private func edit(_ name: String, _ change: (inout TrackEdits) -> Void) {
        guard let hash = track?.contentHash else { return }
        let before = AnalysisCache.shared.edits(hash)
        var after = before
        change(&after)
        guard after != before else { return }
        TrackDetail.setEdits(hash, after, restoring: before, name: name, undo: undo)
    }

    private static func setEdits(_ hash: String, _ edits: TrackEdits, restoring old: TrackEdits, name: String,
                                 undo: UndoManager?) {
        AnalysisCache.shared.setEdits(hash, edits)
        undo?.registerUndo(withTarget: AnalysisCache.shared) { _ in
            setEdits(hash, old, restoring: edits, name: name, undo: undo)
        }
        undo?.setActionName(name)
    }

    // MARK: Controls

    private func controls(_ track: ProjectTrack, _ info: TrackMixInfo) -> some View {
        HStack(spacing: 14) {
            Button { preview.toggle() } label: {
                Label(preview.playing ? "Stop" : "Play from marker", systemImage: preview.playing ? "stop.fill" : "play.fill")
            }
            .help("Plays the file from the white marker (click the waveform to move it)")
            Divider().frame(height: 16)
            HStack(spacing: 4) {
                Text("Bar 1")
                Button { edit("Move Bar 1") { $0.downbeatShift -= 1 } } label: { Image(systemName: "chevron.left") }
                    .help("One beat earlier")
                Button { edit("Move Bar 1") { $0.downbeatShift += 1 } } label: { Image(systemName: "chevron.right") }
                    .help("One beat later")
                if info.edits.downbeatShift != 0 {
                    Text(String(format: "%+d beat%@", info.edits.downbeatShift, abs(info.edits.downbeatShift) == 1 ? "" : "s"))
                        .foregroundStyle(.orange)
                }
            }
            Divider().frame(height: 16)
            Stepper(value: Binding(get: { track.keyShift }, set: { v in
                document.perform("Key Shift", undo: undo) { p in
                    if let i = p.index(of: track.id) { p.tracks[i].keyShift = v }
                }
            }), in: -6...6) {
                Text("Key shift \(track.keyShift == 0 ? "0" : String(format: "%+d", track.keyShift))"
                     + (track.key.map { " → \($0)" } ?? ""))
                    .foregroundStyle(track.keyShift == 0 ? Color.primary : .orange)
            }
            .fixedSize()
            Spacer()
            if info.edits.structure != nil {
                Button("Revert Sections") { edit("Revert Sections") { $0.structure = nil } }
            }
        }
        .controlSize(.small)
    }

    private func cueRow(_ info: TrackMixInfo) -> some View {
        HStack(spacing: 6) {
            Text("Hot cues").font(.caption).foregroundStyle(.secondary)
            ForEach(0..<8, id: \.self) { n in
                let cue = info.edits.cues[n]
                Button {
                    if let cue { preview.caret = cue * info.baseGrid.sampleRate; preview.playFromCaret() }
                    else { edit("Set Hot Cue") { $0.cues[n] = preview.caret / info.baseGrid.sampleRate } }
                } label: {
                    Text("\(n + 1)").frame(width: 18)
                }
                .tint(cue == nil ? nil : .orange)
                .buttonStyle(.bordered)
                .contextMenu {
                    Button("Set to Marker") { edit("Set Hot Cue") { $0.cues[n] = preview.caret / info.baseGrid.sampleRate } }
                    Button("Clear") { edit("Clear Hot Cue") { $0.cues[n] = nil } }.disabled(cue == nil)
                }
                .help(cue.map { String(format: "Cue %d at %d:%05.2f: click to play, right-click to move or clear", n + 1,
                                       Int($0) / 60, $0.truncatingRemainder(dividingBy: 60)) }
                      ?? "Empty: click to set at the marker")
            }
            Spacer()
            Text("Right-click a section to relabel, split or merge · drag a boundary to move it")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .controlSize(.small)
    }

    private func facts(_ track: ProjectTrack) -> some View {
        let analysis = info?.analysis
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            row("Key in use", track.key.map { "\($0) (\($0.name))" + (track.keyShift != 0 ? "  · file \(track.baseKey?.description ?? "–")" : "") } ?? "–")
            row("Analysed", [track.analysedKey?.description, track.analysedBpm.map { String(format: "%g BPM", $0) }]
                .compactMap { $0 }.joined(separator: " · "))
            row("File tags", [track.tagKey?.description, track.tagBpm.map { String(format: "%g BPM", $0) }]
                .compactMap { $0 }.joined(separator: " · "))
            if track.isOverridden {
                row("Override", [track.keyOverride?.description, track.bpmOverride.map { String(format: "%g BPM", $0) }]
                    .compactMap { $0 }.joined(separator: " · "))
            }
            if let a = analysis {
                row("Beat grid", String(format: "confidence %.2f", a.beatConfidence))
                if let s = info?.baseStructure {
                    row("Structure", s.edited ? "corrected by you"
                        : String(format: "confidence %.2f%@", s.confidence,
                                 s.confidence < TransitionDefaults.minStructureConfidence ? " (low: mixes on phrases)" : ""))
                }
                row("Duration", String(format: "%d:%02d", Int(a.duration) / 60, Int(a.duration) % 60))
            }
            row("File", track.filename)
        }
        .font(.callout)
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v.isEmpty ? "–" : v).textSelection(.enabled).lineLimit(2)
        }
    }
}

/// Whole-track waveform with the section strip, bar ruler, cue flags and a
/// marker. Click to place the marker (snaps to the beat), drag a boundary to
/// move it, right-click a section for the rest.
struct StructureEditor: View {
    let info: TrackMixInfo
    let wave: WaveformSummary
    @ObservedObject var preview: FilePreview
    let edit: (String, (inout TrackEdits) -> Void) -> Void
    @State private var hoverX: CGFloat = 0
    @State private var drag: (index: Int, bar: Int)?

    private let stripH: CGFloat = 20, rulerH: CGFloat = 14

    private var grid: TrackGrid { info.baseGrid }
    private var structure: TrackStructure? { info.baseStructure }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in draw(ctx, size) }
                TimelineView(.periodic(from: .now, by: 1.0 / 20)) { _ in
                    Rectangle().fill(Color.white).frame(width: 1.5, height: geo.size.height)
                        .offset(x: x(preview.position, w))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { if case let .active(p) = $0 { hoverX = p.x } }
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { v in dragChanged(v.startLocation.x, v.location.x, w) }
                .onEnded { _ in dragEnded() })
            .onTapGesture(coordinateSpace: .local) { p in
                preview.caret = snapToBeat(frame(p.x, w))
                if preview.playing { preview.playFromCaret() }
            }
            .contextMenu { menu(w) }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.85)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func x(_ frame: Double, _ w: CGFloat) -> CGFloat { CGFloat(frame / Double(max(grid.frames, 1))) * w }
    private func frame(_ x: CGFloat, _ w: CGFloat) -> Double { Double(x / max(w, 1)) * Double(grid.frames) }
    private func bar(_ x: CGFloat, _ w: CGFloat) -> Int {
        Int(((frame(x, w) - grid.firstBeat) / grid.barLength).rounded())
    }
    private func snapToBeat(_ f: Double) -> Double {
        max(0, grid.firstBeat + ((f - grid.firstBeat) / grid.beatLength).rounded() * grid.beatLength)
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let waveTop = rulerH, waveH = size.height - rulerH - stripH
        // Waveform.
        let n = wave.peak.count
        let mid = waveTop + waveH / 2
        if n > 0 {
            let cols = max(1, Int(size.width))
            for c in 0..<cols {
                let a = c * n / cols, b = max(a + 1, (c + 1) * n / cols)
                var pk: UInt8 = 0, lo = 0, mi = 0, hi = 0
                for i in a..<min(b, n) {
                    pk = max(pk, wave.peak[i]); lo += Int(wave.low[i]); mi += Int(wave.mid[i]); hi += Int(wave.high[i])
                }
                let total = Double(max(lo + mi + hi, 1))
                let colour = Color(red: Double(lo) / total * 1.6, green: Double(mi) / total * 1.4, blue: Double(hi) / total * 2.2)
                let h = Double(pk) / 255 * (waveH / 2 - 2)
                ctx.fill(Path(CGRect(x: Double(c), y: mid - h, width: 1, height: max(h * 2, 1))), with: .color(colour))
            }
        }
        // Bar ruler: every 8 bars (phrases brighter), numbers every 16.
        let phrase = structure?.phraseOffset ?? 0
        var b = 0
        while grid.barFrame(Double(b)) < Double(grid.frames) {
            let px = x(grid.barFrame(Double(b)), size.width)
            if b % 8 == phrase % 8 || b == 0 {
                ctx.fill(Path(CGRect(x: px, y: waveTop, width: 0.5, height: waveH)), with: .color(.white.opacity(0.2)))
            }
            if b % 16 == 0 {
                ctx.draw(Text("\(b + 1)").font(.system(size: 8)).foregroundStyle(.white.opacity(0.6)),
                         at: CGPoint(x: px + 2, y: rulerH / 2), anchor: .leading)
            }
            b += 4
        }
        // Sections (with an in-progress boundary drag).
        if var s = structure {
            if let drag { s.moveBoundary(drag.index, to: drag.bar) }
            SectionStrip.draw(ctx, y: size.height - stripH, height: stripH, from: 0, to: size.width) { px in
                let f = frame(px, size.width)
                let bar = Int(((f - grid.firstBeat) / grid.barLength).rounded(.down))
                return s.index(at: max(bar, 0)).map { s.sections[$0].label }
            }
            for i in s.sections.indices.dropFirst() {
                let px = x(grid.barFrame(Double(s.sections[i].startBar)), size.width)
                ctx.fill(Path(CGRect(x: px - 1, y: waveTop, width: 2, height: size.height - waveTop)),
                         with: .color(.white.opacity(drag?.index == i ? 0.9 : 0.45)))
            }
        }
        // Cues and the marker.
        let cues = info.edits.cues.enumerated().compactMap { n, c in c.map { (n + 1, x($0 * grid.sampleRate, size.width)) } }
        SectionStrip.drawCues(ctx, cues, top: waveTop, height: waveH)
        let cx = x(preview.caret, size.width)
        ctx.fill(Path(CGRect(x: cx - 0.5, y: 0, width: 1, height: size.height)), with: .color(.white.opacity(0.8)))
        ctx.fill(Path { p in
            p.move(to: CGPoint(x: cx - 4, y: 0)); p.addLine(to: CGPoint(x: cx + 4, y: 0)); p.addLine(to: CGPoint(x: cx, y: 6))
        }, with: .color(.white))
    }

    // MARK: Editing

    private func boundary(near px: CGFloat, _ w: CGFloat) -> Int? {
        guard let s = structure else { return nil }
        return s.sections.indices.dropFirst().min { a, b in
            abs(x(grid.barFrame(Double(s.sections[a].startBar)), w) - px) < abs(x(grid.barFrame(Double(s.sections[b].startBar)), w) - px)
        }.flatMap { abs(x(grid.barFrame(Double(s.sections[$0].startBar)), w) - px) < 6 ? $0 : nil }
    }

    private func dragChanged(_ start: CGFloat, _ now: CGFloat, _ w: CGFloat) {
        if drag == nil {
            guard let i = boundary(near: start, w) else { return }
            drag = (i, structure!.sections[i].startBar)
        }
        drag?.bar = bar(now, w)
    }

    private func dragEnded() {
        guard let d = drag, var s = structure else { drag = nil; return }
        drag = nil
        guard s.sections[d.index].startBar != d.bar else { return }
        s.moveBoundary(d.index, to: d.bar)
        edit("Move Section Boundary") { $0.structure = s }
    }

    @ViewBuilder private func menu(_ w: CGFloat) -> some View {
        if let s = structure {
            let at = max(0, min(bar(hoverX, w), s.bars - 1))
            let i = s.index(at: at) ?? 0
            Text("Bar \(at + 1) · \(s.sections[i].label.title)")
            Menu("Relabel Section") {
                ForEach(SectionLabel.allCases, id: \.self) { l in
                    Button(l.title) { var c = s; c.relabel(i, l); edit("Relabel Section") { $0.structure = c } }
                }
            }
            Button("Split Section at Bar \(at + 1)") {
                var c = s; c.split(at: at); edit("Split Section") { $0.structure = c }
            }.disabled(s.sections[i].startBar == at)
            Button("Merge with Previous Section") {
                var c = s; c.merge(i); edit("Merge Sections") { $0.structure = c }
            }.disabled(i == 0)
            Divider()
        }
        Menu("Set Hot Cue Here") {
            ForEach(0..<8, id: \.self) { n in
                Button("Cue \(n + 1)") {
                    let f = snapToBeat(frame(hoverX, w))
                    edit("Set Hot Cue") { $0.cues[n] = f / grid.sampleRate }
                }
            }
        }
    }
}

/// Plays the original file from a marker (for checking sections and bar 1 by ear).
@MainActor
final class FilePreview: ObservableObject {
    @Published var caret: Double = 0          // native frames
    @Published private(set) var playing = false
    private(set) var url: URL?
    private var player: AVAudioPlayer?
    private var rate: Double = 44100
    private var timer: Timer?

    var position: Double {
        guard let player, playing else { return caret }
        return player.currentTime * rate
    }

    func load(_ url: URL) {
        stop()
        self.url = url
        player = try? AVAudioPlayer(contentsOf: url)
        rate = player?.format.sampleRate ?? 44100
        player?.prepareToPlay()
    }

    func toggle() { playing ? stop() : playFromCaret() }

    func playFromCaret() {
        guard let player else { return }
        player.currentTime = caret / rate
        player.play()
        playing = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if let self, self.player?.isPlaying != true { self.playing = false; self.timer?.invalidate() }
            }
        }
    }

    func stop() {
        player?.pause()
        playing = false
        timer?.invalidate()
    }
}
