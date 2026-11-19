import Foundation

/// Where Pregame keeps its data: Application Support/Pregame and Caches/Pregame.
/// The app runs in the App Sandbox (ADR-0003), where these resolve inside its
/// container, ~/Library/Containers/<bundle id>/Data/Library/….
///
/// Before the sandbox, the app (then called Harmonizer) kept its data in
/// ~/Library/Application Support/Harmonizer. `copyLegacyDataIfNeeded()` copies
/// it in once, at launch; the app may read that folder through a read-only
/// entitlement exception (scripts/Pregame.entitlements).
public enum DataFolders {
    static let name = "Pregame"
    static let legacyName = "Harmonizer"
    /// Written once the old data has been copied in, so it's only done once.
    static let copiedMarker = ".copied-from-harmonizer"

    /// Application Support/Pregame
    public static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
    }

    /// Caches/Pregame
    public static var caches: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
    }

    /// The user's home folder. Inside the sandbox, NSHomeDirectory() and
    /// FileManager's home are the container, so ask the user database.
    public static var userHome: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// ~/Library/Application Support/Harmonizer: the data from before the sandbox.
    public static var legacyApplicationSupport: URL {
        userHome.appendingPathComponent("Library/Application Support/\(legacyName)", isDirectory: true)
    }

    /// Copy the data from before the sandbox in, once. Call at launch, before
    /// anything opens the caches.
    public static func copyLegacyDataIfNeeded() {
        do {
            try copyLegacyData(from: legacyApplicationSupport, to: applicationSupport)
        } catch {
            NSLog("Pregame: couldn't copy the data from \(legacyApplicationSupport.path): \(error)")
        }
    }

    /// Copy everything in `old` into `new`, keeping whatever `new` already has,
    /// then mark `new` so it's never done again. `old` is left as it was. On
    /// APFS the copies are clones, so even gigabytes of stems take no time or
    /// space. Returns whether anything was copied.
    @discardableResult
    static func copyLegacyData(from old: URL, to new: URL) throws -> Bool {
        let fm = FileManager.default
        let marker = new.appendingPathComponent(copiedMarker)
        guard !fm.fileExists(atPath: marker.path) else { return false }
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        let copied = fm.fileExists(atPath: old.path) ? try merge(old, into: new) : 0
        // Only after everything is in: if a copy failed, the next launch tries again.
        try Data().write(to: marker)
        return copied > 0
    }

    /// Copy each item of `source` that `destination` doesn't have yet, going
    /// into folders both have. Returns how many items were copied.
    private static func merge(_ source: URL, into destination: URL) throws -> Int {
        let fm = FileManager.default
        var copied = 0
        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            var isFolder: ObjCBool = false
            if fm.fileExists(atPath: target.path, isDirectory: &isFolder) {
                if isFolder.boolValue, (try item.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
                    copied += try merge(item, into: target)
                }
            } else {
                // Under a temporary name first, so a copy cut short is never
                // taken for a finished one on the next try.
                let partial = destination.appendingPathComponent(".partial-\(UUID().uuidString)")
                do {
                    try fm.copyItem(at: item, to: partial)
                    try fm.moveItem(at: partial, to: target)
                } catch {
                    try? fm.removeItem(at: partial)
                    throw error
                }
                copied += 1
            }
        }
        return copied
    }

    /// A path to show the user, starting with ~ when it's in their home folder
    /// (the real one, so a container path reads ~/Library/Containers/…).
    public static func displayPath(_ url: URL) -> String {
        let home = userHome.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
