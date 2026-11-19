import Foundation
import XCTest
@testable import PregameCore

/// The app was renamed from Harmonizer to Pregame, but its data stays in the old
/// folders until the sandbox work moves it (#9), so existing analysis, stems,
/// presets and the compiled Core ML model are still found.
final class DataFolderTests: XCTestCase {
    private let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    private let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]

    func testAnalysisIsStillCachedInTheHarmonizerFolder() {
        XCTAssertEqual(AnalysisCache.shared.directory.standardizedFileURL,
                       support.appendingPathComponent("Harmonizer/Analysis").standardizedFileURL)
    }

    func testStemsAreStillCachedInTheHarmonizerFolder() {
        XCTAssertEqual(StemCache.shared.directory.standardizedFileURL,
                       support.appendingPathComponent("Harmonizer/Stems").standardizedFileURL)
    }

    func testPresetsAreStillInTheHarmonizerFolder() {
        XCTAssertEqual(PresetStore.shared.url.standardizedFileURL,
                       support.appendingPathComponent("Harmonizer/Presets.json").standardizedFileURL)
    }

    func testTheCompiledModelIsStillInTheHarmonizerCache() {
        XCTAssertEqual(StemSeparator.coreMLCacheURL.standardizedFileURL,
                       caches.appendingPathComponent("Harmonizer/CoreML").standardizedFileURL)
    }
}
