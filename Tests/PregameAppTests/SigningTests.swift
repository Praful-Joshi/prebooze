import Foundation
import XCTest

/// Every build is signed with one self-signed identity and the hardened runtime,
/// so macOS sees the same app across rebuilds and keeps its folder permissions
/// (docs/signing.md). CI checks the signatures of two real builds; these check
/// the parts that need no certificate.
final class SigningTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func run(_ executable: URL, _ arguments: [String] = [],
                     environment: [String: String] = [:]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Without the identity the build stops before compiling anything and says
    /// how to create it, instead of silently falling back to ad hoc signing.
    func testTheBuildFailsClearlyWithoutTheSigningIdentity() throws {
        let missing = "Pregame Missing Identity \(UUID().uuidString)"
        let result = try run(Self.root.appendingPathComponent("scripts/build-app.sh"), environment: ["PREGAME_SIGNING_IDENTITY": missing])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains(missing), result.output)
        XCTAssertTrue(result.output.contains("scripts/make-signing-identity.sh"), result.output)
        XCTAssertTrue(result.output.contains("docs/signing.md"), result.output)
        XCTAssertFalse(result.output.contains("Compiling"), "checked the identity only after building")
    }

    /// The certificate and its key live in the developer's keychain and backup,
    /// never in the repo.
    func testNoSigningKeysAreCommitted() throws {
        let git = try run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", Self.root.path, "ls-files"])
        XCTAssertEqual(git.status, 0, git.output)
        let files = git.output
        let keyExtensions: Set = ["p12", "pfx", "pem", "key", "cer", "crt", "p8", "keychain", "keychain-db"]
        let keys = files.split(separator: "\n").filter { keyExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
        XCTAssertEqual(keys, [])
    }
}
