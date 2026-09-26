import XCTest
@testable import Streamer

final class FolderSourceTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Albums")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    func testNameIsTheFolderName() {
        XCTAssertEqual(FolderSource(url: root).name, "Albums")
    }

    /// Nested folders are walked, and the order follows the path, so numbered tracks play in album order.
    func testFindsAudioRecursivelyInPathOrder() throws {
        try touch("B Album/02 Second.mp3", "B Album/01 First.mp3", "A Album/10 Tenth.flac", "A Album/9 Ninth.m4a", "loose.wav")

        XCTAssertEqual(try relativePaths(), [
            "A Album/9 Ninth.m4a", "A Album/10 Tenth.flac",
            "B Album/01 First.mp3", "B Album/02 Second.mp3",
            "loose.wav",
        ])
    }

    func testSkipsNonAudioAndHiddenFiles() throws {
        try touch("track.MP3", "cover.jpg", "notes.txt", ".DS_Store", "._track.mp3", ".hidden/secret.mp3")

        XCTAssertEqual(try relativePaths(), ["track.MP3"])
    }

    func testEmptyFolderHasNoTracks() throws {
        XCTAssertEqual(try FolderSource(url: root).trackURLs(), [])
    }

    func testMissingFolderThrows() {
        XCTAssertThrowsError(try FolderSource(url: root.appendingPathComponent("gone")).trackURLs())
    }

    private func touch(_ paths: String...) throws {
        for path in paths {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
    }

    private func relativePaths() throws -> [String] {
        let prefix = root.resolvingSymlinksInPath().path + "/"
        return try FolderSource(url: root).trackURLs().map { $0.resolvingSymlinksInPath().path.replacingOccurrences(of: prefix, with: "") }
    }
}
