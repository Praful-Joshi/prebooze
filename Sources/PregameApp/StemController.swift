import AppKit
import Foundation
import PregameCore
import SwiftUI

/// Separates stems in the background, one song at a time, app-wide (the
/// model is loaded once). Songs are queued when a transition uses stem lanes
/// (or all at once from the Mix menu); urgent requests jump the queue.
@MainActor
final class StemController: ObservableObject {
    static let shared = StemController()
    static let finished = Notification.Name("PregameStemsFinished")

    struct Job: Equatable { let hash: String; let url: URL; let title: String }

    @Published private(set) var queue: [Job] = []
    @Published private(set) var current: Job?
    @Published private(set) var progress = 0.0
    @Published private(set) var preparingModel = false
    @Published private(set) var failures: [String: String] = [:]   // hash → message
    @Published private(set) var done = 0

    private var worker: Task<Void, Never>?
    private nonisolated(unsafe) var separator: StemSeparator?

    var busy: Bool { current != nil || !queue.isEmpty }

    enum State: Equatable { case ready, separating(Double), queued, failed(String), missing }

    func state(_ hash: String?) -> State {
        guard let hash else { return .missing }
        if StemCache.shared.has(hash) { return .ready }
        if current?.hash == hash { return .separating(progress) }
        if queue.contains(where: { $0.hash == hash }) { return .queued }
        if let f = failures[hash] { return .failed(f) }
        return .missing
    }

    /// Queue songs that don't have stems yet (`urgent`: ahead of the rest).
    func request(_ tracks: [ProjectTrack], urgent: Bool = false) {
        let jobs = tracks.compactMap { t -> Job? in
            guard let h = t.contentHash, !StemCache.shared.has(h), current?.hash != h, failures[h] == nil else { return nil }
            return Job(hash: h, url: t.url, title: t.title)
        }
        guard !jobs.isEmpty else { return }
        let new = jobs.filter { j in !queue.contains(j) }
        if urgent {
            queue.removeAll { j in jobs.contains(j) }
            queue.insert(contentsOf: jobs, at: 0)
        } else {
            queue += new
        }
        startIfNeeded()
    }

    func retry(_ hash: String) { failures[hash] = nil }

    /// Forget these Tracks' failures (their files may have been found).
    func retry(_ tracks: [ProjectTrack]) {
        for h in tracks.compactMap(\.contentHash) { failures[h] = nil }
    }

    // MARK: STEM files for Mixxx

    @Published private(set) var exporting: (done: Int, total: Int, current: String)?
    @Published private(set) var exportErrors: [String] = []
    private var exportTask: Task<Void, Never>?
    static let exportFolderKey = "stemExportFolder"

    /// Write `.stem.mp4` files (full mix + drums/bass/melody/vocals) for these
    /// songs into `folder`, separating any that aren't separated yet.
    func exportStemFiles(_ tracks: [ProjectTrack], to folder: URL) {
        let todo = tracks.filter { $0.contentHash != nil }
        guard !todo.isEmpty, exportTask == nil else { return }
        UserDefaults.standard.set(folder.path, forKey: StemController.exportFolderKey)
        exportErrors = []
        exporting = (0, todo.count, "")
        exportTask = Task { [weak self] in
            guard let self else { return }
            let access = folder.startAccessingSecurityScopedResource()
            defer { if access { folder.stopAccessingSecurityScopedResource() } }
            for (k, t) in todo.enumerated() {
                let hash = t.contentHash!
                self.exporting = (k, todo.count, t.title)
                if !StemCache.shared.has(hash) {
                    self.request([t], urgent: true)
                    while !StemCache.shared.has(hash), self.failures[hash] == nil, !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                }
                if let f = self.failures[hash] { self.exportErrors.append("\(t.title): \(f)"); continue }
                let out = folder.appendingPathComponent(StemCache.stemFileName(title: t.title, artist: t.artist))
                let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                    Result {
                        let (mix, stems) = try StemCache.shared.stemFileAudio(source: t.url, hash: hash)
                        try StemFile.write(out, mix: mix, stems: stems, sampleRate: StemSeparator.sampleRate,
                                           tags: .init(title: t.title, artist: t.artist))
                    }
                }.value
                if case let .failure(e) = result { self.exportErrors.append("\(t.title): \(e.localizedDescription)") }
            }
            self.exporting = nil
            self.exportTask = nil
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }

    private func startIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, let job = self.queue.first {
                self.queue.removeFirst()
                self.current = job
                self.progress = 0
                let outcome = await self.run(job)
                if case let .failure(e) = outcome { self.failures[job.hash] = e.localizedDescription }
                self.current = nil
                self.done += 1
                NotificationCenter.default.post(name: StemController.finished, object: job.hash)
            }
            self?.worker = nil
        }
    }

    private func run(_ job: Job) async -> Result<Void, Error> {
        let needsModel = separator == nil
        if needsModel { preparingModel = true }
        defer { preparingModel = false }
        return await Task.detached(priority: .userInitiated) { [weak self] () -> Result<Void, Error> in
            do {
                guard let self else { return .success(()) }
                if self.separator == nil { self.separator = try StemSeparator() }
                await MainActor.run { self.preparingModel = false }
                let audio = try decodeAudio(job.url, sampleRate: StemSeparator.sampleRate)
                var last = Date.distantPast
                let stems = try self.separator!.separate(left: audio.left, right: audio.right) { p in
                    if Date().timeIntervalSince(last) > 0.25 {
                        last = Date()
                        Task { @MainActor in self.progress = p }
                    }
                    return true
                }
                try StemCache.shared.store(job.hash, stems: stems, title: job.title)
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
    }
}
