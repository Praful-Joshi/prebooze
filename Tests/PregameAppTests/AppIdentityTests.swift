import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import PregameApp

/// The app is called Pregame everywhere a person sees it (it used to be
/// Harmonizer), and Mix files saved by the old app still open.
final class AppIdentityTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func text(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    private func infoPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("scripts/Info.plist"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func typeDeclarations(_ key: String) throws -> [[String: Any]] {
        try XCTUnwrap(try infoPlist()[key] as? [[String: Any]], "\(key) missing")
    }

    private func extensions(_ declaration: [String: Any]) -> [String] {
        (declaration["UTTypeTagSpecification"] as? [String: Any])?["public.filename-extension"] as? [String] ?? []
    }

    func testTheAppIsCalledPregame() throws {
        let plist = try infoPlist()
        XCTAssertEqual(plist["CFBundleName"] as? String, "Pregame")
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, "Pregame")
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.prafuljoshi.pregame")
    }

    func testTheBuiltExecutableIsTheOneInfoPlistNames() throws {
        XCTAssertEqual(try infoPlist()["CFBundleExecutable"] as? String, "Pregame")
        XCTAssertTrue(try text("Package.swift").contains(#".executable(name: "Pregame""#))
        let script = try text("scripts/build-app.sh")
        XCTAssertTrue(script.contains(#"APP="build/Pregame.app""#))
        XCTAssertTrue(script.contains("--product Pregame"))
        XCTAssertTrue(try text(".github/workflows/ci.yml").contains("--product Pregame"))
    }

    func testMixFilesArePregameMixes() throws {
        let exported = try XCTUnwrap(try typeDeclarations("UTExportedTypeDeclarations").first)
        XCTAssertEqual(exported["UTTypeIdentifier"] as? String, UTType.hmix.identifier)
        XCTAssertEqual(UTType.hmix.identifier, "com.prafuljoshi.pregame.hmix")
        XCTAssertEqual(exported["UTTypeDescription"] as? String, "Pregame Mix")
        XCTAssertEqual(extensions(exported), ["hmix"])

        let document = try XCTUnwrap(try typeDeclarations("CFBundleDocumentTypes").first)
        XCTAssertEqual(document["CFBundleTypeName"] as? String, "Pregame Mix")
    }

    /// A Mac that still has the old app registered may type .hmix files as the
    /// old identifier, so Pregame declares and reads that type too.
    func testMixFilesSavedByTheOldAppStillOpen() throws {
        let legacy = "com.prafuljoshi.harmonizer.hmix"
        let imported = try typeDeclarations("UTImportedTypeDeclarations")
        let declaration = try XCTUnwrap(imported.first { $0["UTTypeIdentifier"] as? String == legacy })
        XCTAssertEqual(extensions(declaration), ["hmix"])

        let document = try XCTUnwrap(try typeDeclarations("CFBundleDocumentTypes").first)
        XCTAssertEqual(Set(document["LSItemContentTypes"] as? [String] ?? []),
                       [UTType.hmix.identifier, legacy])
        XCTAssertEqual(Set(MixDocument.readableContentTypes.map(\.identifier)),
                       [UTType.hmix.identifier, legacy])
        XCTAssertEqual(MixDocument.writableContentTypes.map(\.identifier), [UTType.hmix.identifier])
    }
}
