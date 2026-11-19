import Foundation
import PregameCore

/// The app's settings (output device, timeline height, stem cache size, …) live
/// in its defaults. Sandboxed, those are in the app's container, so the ones
/// saved before the sandbox, in ~/Library/Preferences, are copied over once at
/// launch: Pregame's own first, then those from when the app was called
/// Harmonizer. Anything already set in the sandbox is kept. The app may read
/// these two files through a read-only entitlement exception.
enum LegacyDefaults {
    static let domains = ["com.prafuljoshi.pregame", "com.prafuljoshi.harmonizer"]
    private static let doneKey = "migratedPreSandboxDefaults"

    static var files: [URL] {
        domains.map { DataFolders.userHome.appendingPathComponent("Library/Preferences/\($0).plist") }
    }

    static func migrateIfNeeded() {
        migrate(from: files.map(read), into: .standard)
    }

    static func read(_ file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    static func migrate(from sources: [[String: Any]?], into defaults: UserDefaults) {
        guard !defaults.bool(forKey: doneKey) else { return }
        for source in sources {
            for (key, value) in source ?? [:] where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: doneKey)
    }
}
