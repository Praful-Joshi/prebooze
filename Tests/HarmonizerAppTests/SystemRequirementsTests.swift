import Foundation
import XCTest

/// Prebooze runs on macOS 14 or later. The build target, the app's Info.plist and
/// the README must all say so.
final class SystemRequirementsTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func text(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    func testThePackageTargetsMacOS14() throws {
        XCTAssertTrue(try text("Package.swift").contains("platforms: [.macOS(.v14)]"))
    }

    func testTheAppDeclaresMacOS14AsItsMinimum() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("scripts/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["LSMinimumSystemVersion"] as? String, "14.0")
    }

    func testTheReadmeStatesTheMinimum() throws {
        XCTAssertTrue(try text("README.md").contains("**macOS 14 Sonoma or later.**"))
    }
}
