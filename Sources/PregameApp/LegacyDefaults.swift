import Foundation

/// The app's settings (output device, timeline height, stem cache size, …) live
/// in the defaults domain of its bundle identifier. When the app was renamed
/// from Harmonizer to Pregame that identifier changed, so the old settings are
/// copied over once, at launch. Anything already set in Pregame is kept.
enum LegacyDefaults {
    static let domain = "com.prafuljoshi.harmonizer"
    private static let doneKey = "migratedHarmonizerDefaults"

    static func migrateIfNeeded() {
        migrate(from: UserDefaults.standard.persistentDomain(forName: domain), into: .standard)
    }

    static func migrate(from legacy: [String: Any]?, into defaults: UserDefaults) {
        guard !defaults.bool(forKey: doneKey) else { return }
        for (key, value) in legacy ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: doneKey)
    }
}
