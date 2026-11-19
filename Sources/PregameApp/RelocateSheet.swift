import PregameCore
import SwiftUI

/// Shown when a Mix opens with Tracks that can't be reached: lists their
/// folders, and locating a folder finds every Track inside it. The Mix stays
/// usable without the rest.
struct RelocateSheet: View {
    @ObservedObject var document: MixDocument
    /// Called after a folder was located, so analysis can retry.
    var onFound: () -> Void
    @Environment(\.undoManager) private var undo
    @Environment(\.dismiss) private var dismiss
    @State private var notFoundIn: String?

    private static let shownNames = 4

    var body: some View {
        let missing = document.project.missingFolders()
        VStack(alignment: .leading, spacing: Space.xl) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(missing.isEmpty ? "All tracks found" : "Some tracks can't be found").font(.headline)
                Text(missing.isEmpty
                     ? "Save the mix to remember where they are."
                     : "Show Pregame where these folders are now. Locating a folder finds every track inside it.")
                    .foregroundStyle(.secondary)
            }
            if !missing.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.l) {
                        ForEach(missing) { row($0) }
                    }
                }
                .frame(maxHeight: 360)
            }
            if let notFoundIn {
                Label("No missing tracks were in “\(notFoundIn)”.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Ink.warning)
            }
            HStack {
                Spacer()
                Button(missing.isEmpty ? "Done" : "Continue Without Them") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xxl)
        .frame(width: 520)
        .animation(Motion.settle, value: missing)
    }

    private func row(_ m: MissingFolder) -> some View {
        HStack(alignment: .top, spacing: Space.l) {
            Image(systemName: "folder.badge.questionmark").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(m.folder.lastPathComponent).fontWeight(.medium)
                Text(m.folder.path).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Text(names(m)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Locate…") { locate(m.folder) }
        }
    }

    private func names(_ m: MissingFolder) -> String {
        let shown = m.trackNames.prefix(Self.shownNames).joined(separator: ", ")
        let more = m.trackNames.count - Self.shownNames
        return more > 0 ? "\(shown) and \(more) more" : shown
    }

    private func locate(_ folder: URL) {
        guard let picked = Panels.chooseFolder(prompt: "Locate",
                                               message: "Where is “\(folder.lastPathComponent)” now?",
                                               start: nearestExisting(folder)) else { return }
        var found = 0
        document.perform("Locate Folder", undo: undo) { found = $0.relocate(folder, to: picked) }
        notFoundIn = found == 0 ? picked.lastPathComponent : nil
        if found > 0 { onFound() }
    }

    /// Start the panel as close to the old folder as still exists.
    private func nearestExisting(_ folder: URL) -> URL? {
        var url = folder
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}
