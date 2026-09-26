import XCTest
@testable import Streamer

@MainActor
final class StreamServerTests: XCTestCase {
    func testStreamsAACWithLiveHeaders() async throws {
        let server = try await startServer()
        let url = URL(string: "http://127.0.0.1:\(server.boundPort!)/stream")!
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "audio/aac")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Cache-Control"), "no-cache")
        XCTAssertNil(http.value(forHTTPHeaderField: "Content-Length"))

        var first: [UInt8] = []
        for try await byte in bytes {
            first.append(byte)
            if first.count == 2 { break }
        }
        XCTAssertEqual(first, [0xFF, 0xF1])
    }

    func testAnythingElseIsNotFound() async throws {
        let server = try await startServer()
        let url = URL(string: "http://127.0.0.1:\(server.boundPort!)/other")!
        let (_, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
    }

    func testPortInUseThrows() async throws {
        let first = try await startServer()
        let second = StreamServer(port: first.boundPort!, broadcaster: Broadcaster(source: FolderSource(url: URL(fileURLWithPath: "/nonexistent"))))
        do {
            try await second.start()
            XCTFail("expected the port to be taken")
        } catch {}
    }

    // MARK: Helpers

    /// A server on a free port, playing a folder with one short tone in it.
    private func startServer() async throws -> StreamServer {
        let folder = try TestAudio.makeFolder()
        try TestAudio.writeTone(to: folder.appendingPathComponent("tone.aiff"), seconds: 1)

        let server = StreamServer(port: 0, broadcaster: Broadcaster(source: FolderSource(url: folder)))
        try await server.start()
        addTeardownBlock { @MainActor in
            server.stop()
            try? FileManager.default.removeItem(at: folder)
        }
        return server
    }
}
