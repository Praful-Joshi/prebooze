import HarmonizerCore
import SwiftUI

/// The one transport (window toolbar): previous/next transition, play,
/// clock, loop the current transition, follow the playhead.
struct TransportBar: View {
    @ObservedObject var document: MixDocument
    @ObservedObject var player: MixPlayerModel
    @ObservedObject var editor: TransitionEditorModel
    @Environment(\.undoManager) private var undo
    @State private var clockHover = false

    var body: some View {
        HStack(spacing: 2) {
            Button { editor.jump(by: -1) } label: { Image(systemName: "backward.end.fill") }
                .help("Previous transition")
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button { player.togglePlay() } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 18)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help("Play / pause (Space)")
            .disabled(player.layout == nil)
            Button { editor.jump(by: 1) } label: { Image(systemName: "forward.end.fill") }
                .help("Next transition")
                .keyboardShortcut(.rightArrow, modifiers: .command)
            clock.padding(.horizontal, 8)
            if player.loading { ProgressView().controlSize(.mini).transition(.opacity) }
            Toggle(isOn: Binding(get: { editor.loop }, set: { editor.setLoop($0) })) {
                Image(systemName: "repeat")
            }
            .toggleStyle(.button)
            .help("Loop the current transition and its lead bars (L)")
            .keyboardShortcut("l", modifiers: [])
            Toggle(isOn: $editor.follow) {
                Image(systemName: editor.follow ? "scope" : "pin.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .toggleStyle(.button)
            .help(editor.follow ? "Following the playhead from transition to transition. Click to pin this one."
                                : "Pinned to this transition. Click to follow the playhead again.")
            .disabled(editor.loop)
            Menu {
                ForEach([4, 8, 16], id: \.self) { bars in
                    Button {
                        document.perform("Change Lead-in", undo: undo) { $0.transitionDefaults.previewLeadBars = bars }
                    } label: {
                        if bars == document.project.transitionDefaults.previewLeadBars {
                            Label("\(bars) bars", systemImage: "checkmark")
                        } else { Text("\(bars) bars") }
                    }
                }
            } label: { Text("Lead \(document.project.transitionDefaults.previewLeadBars)").font(.caption) }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Bars of each track shown and looped either side of a transition")
        }
        .animation(.smooth(duration: 0.2), value: player.loading)
    }

    private var clock: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let pos = player.position, total = player.layout?.length ?? 0
            Group {
                if clockHover {
                    Text("−\(Self.clock(max(0, total - pos)))")
                } else {
                    Text("\(Self.clock(pos)) / \(Self.clock(total))")
                }
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 120)
            .onAppear { player.tick(); editor.tick() }
            .onChange(of: pos) { player.tick(); editor.tick() }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { clockHover = h } }
        .help("Hover for time remaining")
    }

    static func clock(_ frames: Int) -> String {
        let s = Int(Double(frames) / mixSampleRate)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// A thin progress line under the toolbar while tracks are being analysed.
struct AnalysisProgressLine: View {
    @ObservedObject var analysis: AnalysisController

    var body: some View {
        ZStack(alignment: .topLeading) {
            if analysis.running {
                GeometryReader { g in
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(8, g.size.width * analysis.progress), height: 2)
                        .animation(.smooth, value: analysis.progress)
                }
                .frame(height: 2)
                .help("Analysing \(analysis.done)/\(analysis.total): \(analysis.current)")
                .transition(.opacity)
            } else if !analysis.failures.isEmpty {
                Label("\(analysis.failures.count) couldn't be read", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).padding(4)
                    .background(.regularMaterial, in: Capsule())
                    .help(analysis.failures.joined(separator: "\n"))
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .animation(.easeOut(duration: 0.3), value: analysis.running)
    }
}

/// STEM export progress (top right of the timeline).
struct StemExportStatus: View {
    @ObservedObject var stems = StemController.shared

    var body: some View {
        Group {
            if let e = stems.exporting {
                HStack(spacing: 6) {
                    ProgressView(value: Double(e.done), total: Double(max(e.total, 1))).frame(width: 70)
                    Text("STEM \(e.done + 1)/\(e.total): \(e.current)").lineLimit(1)
                }
                .help("Writing .stem.mp4 files for Mixxx (separating songs first where needed)")
            } else if !stems.exportErrors.isEmpty {
                Label("\(stems.exportErrors.count) STEM file(s) failed", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help(stems.exportErrors.joined(separator: "\n"))
            }
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background { if stems.exporting != nil || !stems.exportErrors.isEmpty { Capsule().fill(.regularMaterial) } }
        .padding(8)
        .animation(.smooth, value: stems.exporting?.done)
    }
}
