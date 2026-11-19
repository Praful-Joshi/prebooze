import Foundation
import XCTest
@testable import PregameCore

/// A Mix finds its Tracks' files again after a relaunch, a move, or (later)
/// the sandbox: through bookmarks, and by re-locating whole folders.
final class TrackFileTests: XCTestCase {
    var dir: URL!
    let fm = FileManager.default

    override func setUp() {
        // Resolved, so paths compare equal to what bookmarks resolve to (/private/var).
        // (resolvingSymlinksInPath would turn /private/var back into /var.)
        let real = realpath(TestFiles.tempDir().path, nil)!
        dir = URL(fileURLWithPath: String(cString: real), isDirectory: true)
        free(real)
    }

    override func tearDown() {
        try? fm.removeItem(at: dir)
    }

    /// A short audio file at `relative` under the test folder.
    @discardableResult
    func audioFile(_ relative: String) throws -> URL {
        let url = dir.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SyntheticAudio.tone(frequency: 440, seconds: 0.2).write(to: url)
        return url
    }

    func move(_ from: String, to: String) throws {
        let target = dir.appendingPathComponent(to)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: dir.appendingPathComponent(from), to: target)
    }

    /// Save, then open the way a document does.
    func reopen(_ project: MixProject) throws -> MixProject {
        var opened = try MixProject.fromFileData(try project.fileData())
        opened.locateFiles(holding: TrackFileAccess())
        return opened
    }

    /// A Mix saved before bookmarks: the same JSON with only paths.
    func oldFormat(_ project: MixProject) throws -> MixProject {
        var stripped = project
        for i in stripped.tracks.indices { stripped.tracks[i].bookmark = nil }
        let data = try stripped.fileData()
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("bookmark"))
        return try MixProject.fromFileData(data)
    }

    func folder(_ relative: String) -> URL { dir.appendingPathComponent(relative) }

    // MARK: -

    func testSavedMixFindsItsTracksAfterTheirFolderMoves() throws {
        var project = MixProject()
        project.tracks = [ProjectTrack.from(try audioFile("Music/a.wav")),
                          ProjectTrack.from(try audioFile("Music/b.wav"))]
        XCTAssertTrue(project.tracks.allSatisfy { $0.bookmark != nil }, "Tracks are bookmarked when added")
        let json = String(decoding: try project.fileData(), as: UTF8.self)
        XCTAssertEqual(json.components(separatedBy: "\"bookmark\"").count - 1, 2)

        try move("Music", to: "Moved/Music")
        let opened = try reopen(project)
        XCTAssertEqual(opened.tracks.map(\.path), [folder("Moved/Music/a.wav").path, folder("Moved/Music/b.wav").path])
        XCTAssertEqual(opened.missingFolders(), [])
        // Stale bookmarks were refreshed: they now resolve cleanly to the new place.
        for t in opened.tracks {
            var stale = false
            let url = try URL(resolvingBookmarkData: t.bookmark!, options: .withSecurityScope,
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            XCTAssertFalse(stale)
            XCTAssertEqual(url.path, t.path)
        }
        XCTAssertEqual(try reopen(opened).tracks.map(\.path), opened.tracks.map(\.path))
    }

    func testOldMixWithReachableTracksGetsBookmarksOnOpen() throws {
        var project = MixProject()
        project.tracks = [ProjectTrack.from(try audioFile("Music/a.wav"))]
        var opened = try oldFormat(project)
        opened.locateFiles(holding: TrackFileAccess())
        XCTAssertNotNil(opened.tracks[0].bookmark)
        XCTAssertEqual(opened.missingFolders(), [])
    }

    func testOldMixOffersTheFoldersToRelocate() throws {
        var project = MixProject()
        project.tracks = [ProjectTrack.from(try audioFile("Old/a.wav")),
                          ProjectTrack.from(try audioFile("Old/Sub/b.wav")),
                          ProjectTrack.from(try audioFile("Other/c.wav"))]
        var opened = try oldFormat(project)
        try move("Old", to: "New")
        try move("Other", to: "Elsewhere")
        opened.locateFiles(holding: TrackFileAccess())

        // A folder inside another listed folder is fixed with it, so it isn't listed apart.
        let missing = opened.missingFolders()
        XCTAssertEqual(missing.map(\.folder.path), [folder("Old").path, folder("Other").path])
        XCTAssertEqual(missing.map(\.trackNames), [["a", "b"], ["c"]])

        XCTAssertEqual(opened.relocate(folder("Old"), to: folder("New")), 2)
        XCTAssertEqual(opened.tracks[0].path, folder("New/a.wav").path)
        XCTAssertEqual(opened.tracks[1].path, folder("New/Sub/b.wav").path)
        XCTAssertEqual(opened.missingFolders().map(\.folder.path), [folder("Other").path])

        XCTAssertEqual(opened.relocate(folder("Other"), to: folder("Elsewhere")), 1)
        XCTAssertEqual(opened.missingFolders(), [])
        XCTAssertTrue(opened.tracks.allSatisfy { $0.bookmark != nil })

        // Saved with fresh bookmarks, it survives another move without asking.
        try move("New", to: "Newer")
        let reopened = try reopen(opened)
        XCTAssertEqual(reopened.tracks[1].path, folder("Newer/Sub/b.wav").path)
        XCTAssertEqual(reopened.missingFolders(), [])
    }

    func testTracksThatAreTrulyMissingAreListedByName() throws {
        var project = MixProject()
        project.tracks = [ProjectTrack.from(try audioFile("Old/a.wav")),
                          ProjectTrack.from(try audioFile("Old/b.wav"))]
        project.tracks[1].artist = "Someone"
        var opened = try oldFormat(project)
        try move("Old/a.wav", to: "New/a.wav")
        try fm.removeItem(at: folder("Old"))
        opened.locateFiles(holding: TrackFileAccess())

        XCTAssertEqual(opened.relocate(folder("Old"), to: folder("New")), 1)
        XCTAssertEqual(opened.missingFolders().map(\.id), [folder("Old").path])
        XCTAssertEqual(opened.missingFolders().map(\.trackNames), [["Someone - b"]])
        XCTAssertEqual(opened.tracks.count, 2, "the Mix keeps the missing Track")
    }

    func testDeletedFileWithABookmarkIsMissing() throws {
        var project = MixProject()
        project.tracks = [ProjectTrack.from(try audioFile("Music/a.wav"))]
        try fm.removeItem(at: folder("Music/a.wav"))
        let opened = try reopen(project)
        XCTAssertEqual(opened.missingFolders().map(\.id), [folder("Music").path])
        XCTAssertEqual(opened.missingFolders().map(\.trackNames), [["a"]])
    }
}
