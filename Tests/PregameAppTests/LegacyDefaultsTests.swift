import Foundation
import XCTest
@testable import PregameApp

/// The new bundle identifier gives Pregame a fresh defaults domain, so the
/// settings saved under the old identifier are copied over once.
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
        LegacyDefaults.migrate(from: ["timelineHeight": 220.0, "outputDevice": "uid-1"], into: defaults)
        XCTAssertEqual(defaults.double(forKey: "timelineHeight"), 220)
        XCTAssertEqual(defaults.string(forKey: "outputDevice"), "uid-1")
    }

    func testSettingsAlreadyMadeInPregameWin() {
        defaults.set(180.0, forKey: "timelineHeight")
        LegacyDefaults.migrate(from: ["timelineHeight": 220.0], into: defaults)
        XCTAssertEqual(defaults.double(forKey: "timelineHeight"), 180)
    }

    func testItOnlyHappensOnce() {
        LegacyDefaults.migrate(from: ["timelineHeight": 220.0], into: defaults)
        defaults.removeObject(forKey: "timelineHeight")
        LegacyDefaults.migrate(from: ["timelineHeight": 220.0], into: defaults)
        XCTAssertNil(defaults.object(forKey: "timelineHeight"))
    }

    func testNothingToCopyWhenTheOldAppWasNeverRun() {
        LegacyDefaults.migrate(from: nil, into: defaults)
        XCTAssertNil(defaults.object(forKey: "timelineHeight"))
    }

    func testTheOldDomainIsTheOldBundleIdentifier() {
        XCTAssertEqual(LegacyDefaults.domain, "com.prafuljoshi.harmonizer")
    }
}
