import CryptoKit
import Foundation
import XCTest

/// Pregame updates itself with Sparkle 2 from an EdDSA-signed appcast published
/// with each GitHub Release (docs/updates.md). These check how the app is set up
/// to find and trust updates, and that scripts/make-appcast.sh signs an appcast
/// the app will accept.
final class UpdateTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let repository = "https://github.com/Praful-Joshi/pregame"

    private func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.root.appendingPathComponent(path))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func run(_ executable: String, _ arguments: [String],
                     environment: [String: String] = [:]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
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

    // MARK: - Finding and trusting updates

    /// Each GitHub Release carries the appcast for its version, so "latest"
    /// always answers with the newest release's appcast.
    func testTheAppChecksTheLatestReleasesAppcast() throws {
        XCTAssertEqual(try plist("scripts/Info.plist")["SUFeedURL"] as? String,
                       "\(Self.repository)/releases/latest/download/appcast.xml")
    }

    /// The app carries the EdDSA public key, and accepts only updates and an
    /// appcast signed with its private half.
    func testTheAppTrustsOnlyUpdatesSignedWithItsKey() throws {
        let info = try plist("scripts/Info.plist")
        let key = try XCTUnwrap(info["SUPublicEDKey"] as? String)
        let raw = try XCTUnwrap(Data(base64Encoded: key), "SUPublicEDKey isn't base64")
        XCTAssertNoThrow(try Curve25519.Signing.PublicKey(rawRepresentation: raw), "SUPublicEDKey isn't an Ed25519 public key")
        XCTAssertEqual(info["SURequireSignedFeed"] as? Bool, true, "the appcast itself must be signed too")
        // Sparkle refuses to start with a signed feed unless updates are also
        // verified before they're extracted.
        XCTAssertEqual(info["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
    }

    /// Checks run on their own without asking first; Settings turns them off.
    func testUpdatesAreCheckedAutomatically() throws {
        XCTAssertEqual(try plist("scripts/Info.plist")["SUEnableAutomaticChecks"] as? Bool, true)
    }

    /// In the sandbox, Sparkle installs through its Installer XPC service, which
    /// the app reaches by two Mach service names derived from its bundle ID. It
    /// downloads through its Downloader XPC service, so the app itself still
    /// needs no network access.
    func testTheSandboxedAppInstallsAndDownloadsThroughSparklesServices() throws {
        let info = try plist("scripts/Info.plist")
        XCTAssertEqual(info["SUEnableInstallerLauncherService"] as? Bool, true)
        XCTAssertEqual(info["SUEnableDownloaderService"] as? Bool, true)
        let bundleID = try XCTUnwrap(info["CFBundleIdentifier"] as? String)
        let services = try XCTUnwrap(try plist("scripts/Pregame.entitlements")["com.apple.security.temporary-exception.mach-lookup.global-name"] as? [String])
        XCTAssertEqual(Set(services), ["\(bundleID)-spks", "\(bundleID)-spki"])
    }

    // MARK: - Shipping it

    /// build-app.sh embeds Sparkle and signs its helpers with the app's own
    /// identity, so an update's signature matches the installed app's.
    func testTheBuildEmbedsAndSignsSparkle() throws {
        let script = try String(contentsOf: Self.root.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("Contents/Frameworks/Sparkle.framework"), "Sparkle isn't embedded")
        for helper in ["XPCServices/Installer.xpc", "XPCServices/Downloader.xpc", "Autoupdate", "Updater.app"] {
            XCTAssertTrue(script.contains(helper), "\(helper) isn't signed")
        }
        // Sparkle's packaged Downloader has no entitlements of its own to keep.
        XCTAssertTrue(script.contains("--entitlements .build/checkouts/Sparkle/Downloader/Downloader.entitlements"),
                      "the Downloader isn't signed with its network entitlement")
    }

    /// Sparkle is MIT-licensed, so its notice and licence travel with the app.
    func testSparkleIsCredited() throws {
        let notices = try String(contentsOf: Self.root.appendingPathComponent("THIRD_PARTY_NOTICES.md"), encoding: .utf8)
        XCTAssertTrue(notices.contains("[Sparkle](https://sparkle-project.org)"), "no Sparkle row in the table")
        XCTAssertTrue(notices.contains("**Sparkle:**"), "no Sparkle copyright entry")
        let script = try String(contentsOf: Self.root.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("SPARKLE_LICENSE"), "Sparkle's licence isn't bundled")
    }

    // MARK: - The appcast

    /// A stand-in app with the real Info.plist (version 9.8, build 987),
    /// trusting the given update key, packaged the way a release DMG is.
    private func standInDMG(in work: URL, trusting publicKey: Curve25519.Signing.PublicKey) throws -> URL {
        let app = work.appendingPathComponent("dmg/Pregame.app/Contents")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        var info = try plist("scripts/Info.plist")
        info["CFBundleShortVersionString"] = "9.8"
        info["CFBundleVersion"] = "987"
        info["SUPublicEDKey"] = publicKey.rawRepresentation.base64EncodedString()
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        try Data("#!/bin/sh\n".utf8).write(to: app.appendingPathComponent("MacOS/Pregame"))
        let dmg = work.appendingPathComponent("Pregame-9.8.dmg")
        let made = try run("/usr/bin/hdiutil", ["create", "-quiet", "-volname", "Pregame", "-fs", "HFS+",
                                                "-srcfolder", work.appendingPathComponent("dmg").path, "-format", "UDZO", dmg.path])
        XCTAssertEqual(made.status, 0, made.output)
        return dmg
    }

    /// A throwaway key, in the format generate_keys exports: the base64 seed.
    private func keyFile(in work: URL) throws -> (key: Curve25519.Signing.PrivateKey, file: URL) {
        let key = Curve25519.Signing.PrivateKey()
        let file = work.appendingPathComponent("key-\(UUID().uuidString).txt")
        try key.rawRepresentation.base64EncodedString().write(to: file, atomically: true, encoding: .utf8)
        return (key, file)
    }

    private func temporaryFolder(_ name: String) throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return work
    }

    /// Given a release DMG, the script writes an appcast whose single item
    /// points at that DMG in the version's GitHub Release, and signs both the
    /// DMG and the appcast with the update key.
    func testTheScriptWritesASignedAppcastForADMG() throws {
        let work = try temporaryFolder("appcast")
        defer { try? FileManager.default.removeItem(at: work) }
        let (key, keyFile) = try keyFile(in: work)
        let dmg = try standInDMG(in: work, trusting: key.publicKey)

        let out = work.appendingPathComponent("out")
        let result = try run(Self.root.appendingPathComponent("scripts/make-appcast.sh").path, [dmg.path, out.path],
                             environment: ["PREGAME_SPARKLE_KEY_FILE": keyFile.path])
        XCTAssertEqual(result.status, 0, result.output)

        let appcast = try XMLDocument(contentsOf: out.appendingPathComponent("appcast.xml"))
        let items = try appcast.nodes(forXPath: "//item")
        XCTAssertEqual(items.count, 1)
        let enclosure = try XCTUnwrap(try appcast.nodes(forXPath: "//item/enclosure").first as? XMLElement)
        XCTAssertEqual(enclosure.attribute(forName: "url")?.stringValue,
                       "\(Self.repository)/releases/download/v9.8/Pregame-9.8.dmg")
        XCTAssertEqual(try appcast.nodes(forXPath: "//item/*[local-name()='version']").first?.stringValue, "987")
        XCTAssertEqual(try appcast.nodes(forXPath: "//item/*[local-name()='shortVersionString']").first?.stringValue, "9.8")
        XCTAssertEqual(try appcast.nodes(forXPath: "//item/*[local-name()='minimumSystemVersion']").first?.stringValue, "15.0")

        let signature = try XCTUnwrap(enclosure.attribute(forName: "sparkle:edSignature")?.stringValue)
        let signatureData = try XCTUnwrap(Data(base64Encoded: signature))
        XCTAssertTrue(key.publicKey.isValidSignature(signatureData, for: try Data(contentsOf: dmg)),
                      "the DMG's signature doesn't verify against the update key")

        let text = try String(contentsOf: out.appendingPathComponent("appcast.xml"), encoding: .utf8)
        XCTAssertTrue(text.contains("sparkle-signatures:"), "the appcast itself isn't signed")
    }

    /// Signing with a key the app doesn't trust would publish an update every
    /// installed copy rejects, so the script refuses and writes no appcast.
    func testTheScriptRefusesAKeyTheAppDoesntTrust() throws {
        let work = try temporaryFolder("appcast-wrong-key")
        defer { try? FileManager.default.removeItem(at: work) }
        let trusted = Curve25519.Signing.PrivateKey()
        let (_, otherKeyFile) = try keyFile(in: work)
        let dmg = try standInDMG(in: work, trusting: trusted.publicKey)

        let out = work.appendingPathComponent("out")
        let result = try run(Self.root.appendingPathComponent("scripts/make-appcast.sh").path, [dmg.path, out.path],
                             environment: ["PREGAME_SPARKLE_KEY_FILE": otherKeyFile.path])
        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("SUPublicEDKey"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("appcast.xml").path),
                       "wrote an appcast the app would reject")
    }

    /// Without a DMG the script says how to use it rather than signing nothing.
    func testTheScriptNeedsADMG() throws {
        let result = try run(Self.root.appendingPathComponent("scripts/make-appcast.sh").path, [])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("usage:"), result.output)
    }
}
