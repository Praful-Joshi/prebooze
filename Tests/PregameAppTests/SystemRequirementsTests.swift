import Foundation
import XCTest

/// Pregame runs on macOS 15 or later: the oldest macOS GitHub Actions offers, so
/// the minimum is always tested. The build target, the app's Info.plist, the
/// README and CI must all agree.
final class SystemRequirementsTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func text(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    func testThePackageTargetsMacOS15() throws {
        XCTAssertTrue(try text("Package.swift").contains("platforms: [.macOS(.v15)]"))
    }

    func testTheAppDeclaresMacOS15AsItsMinimum() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("scripts/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["LSMinimumSystemVersion"] as? String, "15.0")
    }

    func testTheReadmeStatesTheMinimum() throws {
        XCTAssertTrue(try text("README.md").contains("**macOS 15 Sequoia or later.**"))
    }

    /// Pull requests test on macOS 26 only, to keep small pushes quick; every
    /// push to main and a weekly run also test on the minimum, macOS 15.
    func testCIBuildsAndTestsOnTheMinimum() throws {
        let ci = try text(".github/workflows/ci.yml")
        XCTAssertTrue(ci.contains(#"github.event_name == 'pull_request' && fromJSON('["macos-26"]') || fromJSON('["macos-15", "macos-26"]')"#))
        XCTAssertTrue(ci.contains("branches: [main]"))
        XCTAssertTrue(ci.contains("schedule:"))
    }
}
