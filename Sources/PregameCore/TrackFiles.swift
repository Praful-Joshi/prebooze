import Foundation

// Finding a Mix's audio files again: each Track keeps a security-scoped
// bookmark next to its path (ADR-0003). Opening a Mix resolves the bookmarks;
// Tracks that still can't be reached are grouped by folder, and re-locating a
// folder fixes every Track under it.

/// Security-scoped access to a Mix's Track files, held while the Mix is open
/// and given up when this is released.
public final class TrackFileAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    public init() {}

    func hold(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        lock.withLock { urls.append(url) }
    }

    deinit {
        for url in urls { url.stopAccessingSecurityScopedResource() }
    }
}

/// A folder the Mix expected Tracks in that can't be reached, and those Tracks' names.
public struct MissingFolder: Hashable, Identifiable, Sendable {
    public var folder: URL
    public var trackNames: [String]
    public var id: String { folder.path }

    /// The closest folder above this one that still exists, to start looking from.
    public var nearestExistingFolder: URL? {
        var url = folder
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    public init(folder: URL, trackNames: [String]) {
        self.folder = folder
        self.trackNames = trackNames
    }
}

extension MixProject {
    /// Find every Track's file, as a document does on open: through its
    /// bookmark (following moves and refreshing stale bookmarks), else at its
    /// path. Reachable Tracks without a bookmark (older Mixes) get one.
    public mutating func locateFiles(holding access: TrackFileAccess) {
        for i in tracks.indices { tracks[i].locateFile(holding: access) }
    }

    /// Folders holding Tracks that can't be reached, with those Tracks by
    /// name. A folder inside another listed folder is part of it, since
    /// re-locating the outer folder fixes both.
    public func missingFolders() -> [MissingFolder] {
        var byFolder: [String: [String]] = [:]
        for t in tracks where !isReachable(t.path) {
            byFolder[(t.path as NSString).deletingLastPathComponent, default: []].append(t.displayName)
        }
        var result: [MissingFolder] = []
        // Sorted, so a folder comes before the folders inside it.
        for folder in byFolder.keys.sorted() {
            if let i = result.firstIndex(where: { isInside(folder, $0.folder.path) }) {
                result[i].trackNames += byFolder[folder]!
            } else {
                result.append(MissingFolder(folder: URL(filePath: folder, directoryHint: .isDirectory),
                                            trackNames: byFolder[folder]!))
            }
        }
        return result.map {
            MissingFolder(folder: $0.folder,
                          trackNames: $0.trackNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        }
    }

    /// The Tracks that were under `folder` are now under `newFolder`: point
    /// every unreachable one whose file is there at it, with a fresh bookmark
    /// and access held. Picking the same folder again grants access to it.
    /// Returns how many Tracks were found.
    @discardableResult
    public mutating func relocate(_ folder: URL, to newFolder: URL, holding access: TrackFileAccess) -> Int {
        let old = folder.path, new = newFolder.path
        var found = 0
        for i in tracks.indices where isInside(tracks[i].path, old) && !isReachable(tracks[i].path) {
            let candidate = (new as NSString).appendingPathComponent(String(tracks[i].path.dropFirst(old.count)))
            guard isReachable(candidate) else { continue }
            tracks[i].path = candidate
            tracks[i].bookmark = nil
            tracks[i].locateFile(holding: access)
            found += 1
        }
        return found
    }

    /// The Mix as saved: every reachable Track has a bookmark, including ones
    /// added without one (imported runs).
    public func bookmarkingReachableFiles() -> MixProject {
        var p = self
        for i in p.tracks.indices where p.tracks[i].bookmark == nil && isReachable(p.tracks[i].path) {
            p.tracks[i].refreshBookmark(at: p.tracks[i].url)
        }
        return p
    }
}

extension ProjectTrack {
    mutating func locateFile(holding access: TrackFileAccess) {
        if let (resolved, stale) = resolveBookmark() {
            access.hold(resolved)
            if canonical(resolved.path) != canonical(path) { path = resolved.path }
            if stale { refreshBookmark(at: resolved) }
        } else if isReachable(path) {
            // An older Mix, or a file replaced in place: bookmark what's there now.
            refreshBookmark(at: url)
            if let (resolved, _) = resolveBookmark() { access.hold(resolved) }
        }
    }

    private func resolveBookmark() -> (URL, stale: Bool)? {
        guard let bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
    }

    mutating func refreshBookmark(at url: URL) {
        bookmark = makeBookmark(url) ?? bookmark
    }
}

/// A read-write bookmark (tags get written back), or nil if the file can't be reached.
func makeBookmark(_ url: URL) -> Data? {
    try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
}

private func isReachable(_ path: String) -> Bool {
    FileManager.default.isReadableFile(atPath: path)
}

/// Whether `path` is somewhere under `folder`.
private func isInside(_ path: String, _ folder: String) -> Bool {
    folder == "/" || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
}

/// The same file seen through /var and /private/var compares equal.
private func canonical(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}
