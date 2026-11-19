import Foundation
import XCTest
@testable import PregameCore

/// Pregame keeps its data in Application Support/Pregame, which is inside the
/// app's container when it runs sandboxed (ADR-0003). Before the sandbox, the
/// app kept it in ~/Library/Application Support/Harmonizer; that folder is
/// copied in once, so analysis, corrections, presets and stems carry over.
final class DataFolderTests: XCTestCase {
    private let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    private let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    private let fm = FileManager.default
    private var root: URL!
    private var old: URL { root.appendingPathComponent("Harmonizer") }
    private var new: URL { root.appendingPathComponent("Pregame") }

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("data-folders-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    // MARK: Where things live

    func testAnalysisIsCachedInThePregameFolder() {
        XCTAssertEqual(AnalysisCache.shared.directory.standardizedFileURL.path,
                       support.appendingPathComponent("Pregame/Analysis").standardizedFileURL.path)
    }

    func testStemsAreCachedInThePregameFolder() {
        XCTAssertEqual(StemCache.shared.directory.standardizedFileURL.path,
                       support.appendingPathComponent("Pregame/Stems").standardizedFileURL.path)
    }

    func testPresetsAreInThePregameFolder() {
        XCTAssertEqual(PresetStore.shared.url.standardizedFileURL.path,
                       support.appendingPathComponent("Pregame/Presets.json").standardizedFileURL.path)
    }

    func testTheCompiledModelIsInThePregameCache() {
        XCTAssertEqual(StemSeparator.coreMLCacheURL.standardizedFileURL.path,
                       caches.appendingPathComponent("Pregame/CoreML").standardizedFileURL.path)
    }

    /// Inside the sandbox the home folder is the container, so the old data is
    /// looked for in the user's real home.
    func testTheOldDataIsLookedForInTheRealHomeFolder() {
        let home = String(cString: getpwuid(getuid())!.pointee.pw_dir)
        XCTAssertEqual(DataFolders.legacyApplicationSupport.standardizedFileURL.path,
                       home + "/Library/Application Support/Harmonizer")
    }

    // MARK: Copying the old data in

    func testTheOldDataIsCopiedIn() throws {
        try write("a", to: "Analysis/abc.json")
        try write("w", to: "Analysis/abc.wave")
        try write("e", to: "Analysis/abc.edits.json")
        try write("p", to: "Presets.json")
        try write("{}", to: "Stems/index.json")
        try write("d", to: "Stems/abc/drums.m4a")

        XCTAssertTrue(try DataFolders.copyLegacyData(from: old, to: new))

        for path in ["Analysis/abc.json", "Analysis/abc.wave", "Analysis/abc.edits.json",
                     "Presets.json", "Stems/index.json", "Stems/abc/drums.m4a"] {
            XCTAssertEqual(read(new.appendingPathComponent(path)), read(old.appendingPathComponent(path)), path)
        }
    }

    func testTheOldDataIsLeftInPlace() throws {
        try write("a", to: "Analysis/abc.json")
        try DataFolders.copyLegacyData(from: old, to: new)
        XCTAssertEqual(read(old.appendingPathComponent("Analysis/abc.json")), "a")
    }

    func testItOnlyHappensOnce() throws {
        try write("a", to: "Analysis/abc.json")
        try DataFolders.copyLegacyData(from: old, to: new)
        try fm.removeItem(at: new.appendingPathComponent("Analysis/abc.json"))   // e.g. the user cleared it

        XCTAssertFalse(try DataFolders.copyLegacyData(from: old, to: new))
        XCTAssertFalse(fm.fileExists(atPath: new.appendingPathComponent("Analysis/abc.json").path))
    }

    func testDataAlreadyInTheNewFolderWins() throws {
        try write("old", to: "Analysis/abc.edits.json")
        try write("old", to: "Analysis/def.json")
        try fm.createDirectory(at: new.appendingPathComponent("Analysis"), withIntermediateDirectories: true)
        try "new".write(to: new.appendingPathComponent("Analysis/abc.edits.json"), atomically: true, encoding: .utf8)

        try DataFolders.copyLegacyData(from: old, to: new)

        XCTAssertEqual(read(new.appendingPathComponent("Analysis/abc.edits.json")), "new")
        XCTAssertEqual(read(new.appendingPathComponent("Analysis/def.json")), "old")
    }

    func testNothingToCopyWhenTheOldAppWasNeverRun() throws {
        XCTAssertFalse(try DataFolders.copyLegacyData(from: old, to: new))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: new.path).filter { !$0.hasPrefix(".") }, [])
        // And it isn't looked for again.
        try write("a", to: "Analysis/abc.json")
        XCTAssertFalse(try DataFolders.copyLegacyData(from: old, to: new))
    }

    // MARK: Showing where it is

    func testPathsInTheRealHomeAreShownFromTilde() {
        let home = String(cString: getpwuid(getuid())!.pointee.pw_dir)
        let container = URL(fileURLWithPath: home + "/Library/Containers/com.prafuljoshi.pregame/Data/Library/Application Support/Pregame")
        XCTAssertEqual(DataFolders.displayPath(container),
                       "~/Library/Containers/com.prafuljoshi.pregame/Data/Library/Application Support/Pregame")
        XCTAssertEqual(DataFolders.displayPath(URL(fileURLWithPath: "/Volumes/Music/x")), "/Volumes/Music/x")
    }

    // MARK: Helpers

    private func write(_ text: String, to path: String) throws {
        let url = old.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
}
