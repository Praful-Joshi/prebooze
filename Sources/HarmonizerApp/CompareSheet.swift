import HarmonizerCore
import SwiftUI

/// Paste another track order and score it with the same settings. If that
/// order costs less than ours, our search missed it; if it costs more, our
/// costs disagree with whatever produced it.
struct CompareSheet: View {
    @ObservedObject var document: MixDocument
    @Environment(\.undoManager) private var undo
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var matched: [UUID] = []
    @State private var unmatched: [String] = []
    @State private var scored = false

    private var project: MixProject { document.project }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Compare with another order").font(.title2.bold())
            Text("Paste the order, one track per line (\"Artist - Title\" or just the title).")
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.callout.monospaced())
                .frame(height: 180)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                .onChange(of: text) { scored = false }

            if scored { results }

            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use This Order") { useOrder() }
                    .disabled(!scored || matched.count < 2)
                    .help("Reorder the mix to the pasted order (undoable).")
                Button("Score") { score() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    @ViewBuilder private var results: some View {
        let theirs = reordered().summary()
        let ours = project.summary()
        let missing = project.included.filter { !matched.contains($0.id) }
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
            GridRow {
                Text("")
                Text("Cost").bold(); Text("🟩").bold(); Text("🟨").bold(); Text("🟦").bold(); Text("🟥").bold()
                Text("Avg gap").bold()
            }
            row("Current order", ours)
            row("Pasted order", theirs)
        }
        .font(.callout.monospacedDigit())
        let delta = theirs.totalCost - ours.totalCost
        Text(delta < -1e-6 ? "The pasted order scores lower: our search missed a better order."
             : delta > 1e-6 ? "The pasted order scores higher under our costs: if you prefer it, our costs need tuning."
             : "Both orders score the same.")
            .font(.callout)
        if !unmatched.isEmpty {
            Text("Couldn't match: " + unmatched.joined(separator: "; ")).foregroundStyle(.orange).font(.caption)
        }
        if !missing.isEmpty {
            Text("In the mix but not in the pasted list: " + missing.map(\.title).joined(separator: ", "))
                .foregroundStyle(.orange).font(.caption)
        }
    }

    private func row(_ title: String, _ s: MixSummary) -> some View {
        GridRow {
            Text(title)
            Text(String(format: "%.1f", s.totalCost))
            Text("\(s.green)"); Text("\(s.yellow)"); Text("\(s.blue)"); Text("\(s.red)")
            Text(String(format: "%.1f", s.avgBpmGap))
        }
    }

    private func score() {
        let r = matchTracklist(text, tracks: project.included)
        matched = r.matched
        unmatched = r.unmatched
        scored = true
    }

    /// The project with matched tracks first in pasted order, the rest after.
    private func reordered() -> MixProject {
        var p = project
        let byId = Dictionary(uniqueKeysWithValues: p.tracks.map { ($0.id, $0) })
        let set = Set(matched)
        p.tracks = matched.compactMap { byId[$0] } + p.tracks.filter { !set.contains($0.id) && $0.include }
            .map { var t = $0; t.include = false; return t } + p.tracks.filter { !$0.include }
        return p
    }

    private func useOrder() {
        let byId = Dictionary(uniqueKeysWithValues: project.tracks.map { ($0.id, $0) })
        let set = Set(matched)
        document.perform("Use Pasted Order", undo: undo) { p in
            p.tracks = matched.compactMap { byId[$0] } + p.tracks.filter { !set.contains($0.id) }
        }
        dismiss()
    }
}
