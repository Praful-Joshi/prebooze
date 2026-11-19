import Foundation
import XCTest
@testable import PregameApp
import PregameCore

/// Settings saved before the sandbox (under Pregame's identifier, or the old
/// Harmonizer one) live in ~/Library/Preferences, which the sandboxed app
/// doesn't read as its defaults, so they're copied over once.
final class LegacyDefaultsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "pregame.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testOldSettingsAreCopiedOver() {
        LegacyDefaults.migrate(from: [["timelineHeight": 220.0], ["outputDevice": "uid-1"]], into: defaults)
        XCTAssertEqual(defaults.double(forKey: "timelineHeight"), 220)
        XCTAssertEqual(defaults.string(forKey: "outputDevice"), "uid-1")
    }

    func testSettingsAlreadyMadeInTheSandboxWin() {
        defaults.set(180.0, forKey: "timelineHeight")
        LegacyDefaults.migrate(from: [["timelineHeight": 220.0]], into: defaults)
        XCTAssertEqual(defaults.double(forKey: "timelineHeight"), 180)
    }

    /// Pregame's own settings are newer than Harmonizer's.
    func testEarlierSourcesWin() {
        LegacyDefaults.migrate(from: [["timelineHeight": 180.0], ["timelineHeight": 220.0]], into: defaults)
        XCTAssertEqual(defaults.double(forKey: "timelineHeight"), 180)
    }

    func testItOnlyHappensOnce() {
        LegacyDefaults.migrate(from: [["timelineHeight": 220.0]], into: defaults)
        defaults.removeObject(forKey: "timelineHeight")
        LegacyDefaults.migrate(from: [["timelineHeight": 220.0]], into: defaults)
        XCTAssertNil(defaults.object(forKey: "timelineHeight"))
    }

    func testNothingToCopyWhenTheOldAppWasNeverRun() {
        LegacyDefaults.migrate(from: [nil, nil], into: defaults)
        XCTAssertNil(defaults.object(forKey: "timelineHeight"))
    }

    func testOldSettingsAreReadFromTheirPreferencesFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: file) }
        try PropertyListSerialization.data(fromPropertyList: ["stemCacheCapBytes": 5_368_709_120], format: .binary, options: 0)
            .write(to: file)
        XCTAssertEqual(LegacyDefaults.read(file)?["stemCacheCapBytes"] as? Int, 5_368_709_120)
        XCTAssertNil(LegacyDefaults.read(file.appendingPathExtension("missing")))
    }

    /// The sandbox lets the app read exactly these files (scripts/Pregame.entitlements).
    func testTheFilesReadAreThePreSandboxOnes() {
        XCTAssertEqual(LegacyDefaults.files.map { DataFolders.displayPath($0) },
                       ["~/Library/Preferences/com.prafuljoshi.pregame.plist",
                        "~/Library/Preferences/com.prafuljoshi.harmonizer.plist"])
    }
}
