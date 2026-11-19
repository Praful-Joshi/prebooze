import PregameCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let hmix = UTType(exportedAs: "com.prafuljoshi.pregame.hmix")
    /// What the app declared .hmix as when it was called Harmonizer. A Mac that
    /// still has the old app registered may type Mix files this way.
    static let legacyHmix = UTType(importedAs: "com.prafuljoshi.harmonizer.hmix")
}

/// A .hmix project. Every user edit goes through `perform`, which registers a
/// snapshot-based undo.
final class MixDocument: ReferenceFileDocument {
    static var readableContentTypes: [UTType] { [.hmix, .legacyHmix] }
    static var writableContentTypes: [UTType] { [.hmix] }

    @Published var project: MixProject

    init() {
        project = MixProject()
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        project = try MixProject.fromFileData(data)
    }

    func snapshot(contentType: UTType) throws -> MixProject { project }

    func fileWrapper(snapshot: MixProject, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try snapshot.fileData())
    }

    /// Apply an undoable edit.
    func perform(_ name: String, undo: UndoManager?, _ change: (inout MixProject) -> Void) {
        let before = project
        change(&project)
        guard project != before else { return }
        registerUndo(name, undo: undo, restoring: before)
    }

    private func registerUndo(_ name: String, undo: UndoManager?, restoring old: MixProject) {
        undo?.registerUndo(withTarget: self) { doc in
            let current = doc.project
            doc.project = old
            doc.registerUndo(name, undo: undo, restoring: current)
        }
        undo?.setActionName(name)
    }

    /// Non-undoable update (analysis results arriving in the background).
    func silently(_ change: (inout MixProject) -> Void) {
        change(&project)
    }
}
