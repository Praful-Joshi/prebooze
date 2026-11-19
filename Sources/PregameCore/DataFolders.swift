import Foundation

/// Where Pregame keeps its data. The app used to be called Harmonizer, and its
/// data stays in the Harmonizer folders until the App Sandbox work moves it
/// (#9), so analysis, stems, presets and the compiled model survive the rename.
public enum DataFolders {
    static let name = "Harmonizer"

    /// ~/Library/Application Support/Harmonizer
    public static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
    }

    /// ~/Library/Caches/Harmonizer
    public static var caches: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
    }
}
