import Foundation

extension Bundle {
    /// PregameCore's resources (config.json, transitions.json). In Pregame.app
    /// they're in Contents/Resources, where SwiftPM's generated `Bundle.module`
    /// doesn't look: it checks next to the .app and in the build folder, so the
    /// app would only launch on the Mac that built it. Tests and `swift run`
    /// fall back to `Bundle.module`.
    static let pregameCore: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Pregame_PregameCore.bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }()
}
