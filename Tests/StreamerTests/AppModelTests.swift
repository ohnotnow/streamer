import XCTest
@testable import Streamer

@MainActor
final class AppModelTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "StreamerTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    /// Added folders, the chosen source and the sharing switch survive a restart.
    func testSettingsSurviveARestart() {
        let defaults = makeDefaults()
        let model = AppModel(defaults: defaults)
        model.addFolder(URL(fileURLWithPath: "/tmp/Blues"))
        model.addFolder(URL(fileURLWithPath: "/tmp/Jazz"))
        model.addFolder(URL(fileURLWithPath: "/tmp/Blues"))  // again: no duplicate
        model.sharesOnNetwork = true

        let restarted = AppModel(defaults: defaults)
        XCTAssertEqual(restarted.folders.map(\.name), ["Blues", "Jazz"])
        XCTAssertEqual(restarted.selected?.name, "Blues")
        XCTAssertTrue(restarted.sharesOnNetwork)
    }

    func testStreamURLIsLoopbackUnlessSharing() {
        let model = AppModel(defaults: makeDefaults())
        XCTAssertEqual(model.streamURL, "http://127.0.0.1:8090/stream")
        model.sharesOnNetwork = true
        XCTAssertTrue(model.streamURL.hasSuffix(".local:8090/stream"), model.streamURL)
    }

    func testIconFollowsTheStream() async throws {
        let folder = try TestAudio.makeFolder()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try TestAudio.writeTone(to: folder.appendingPathComponent("tone.aiff"), seconds: 1)
        let model = AppModel(defaults: makeDefaults(), port: 0)
        XCTAssertEqual(model.icon, .off)

        model.addFolder(folder)
        await model.start()
        defer { model.stop() }
        XCTAssertEqual(model.icon, .ready)
        model.broadcaster?.add(SilentListener())
        XCTAssertEqual(model.icon, .onAir)
        model.stop()
        XCTAssertEqual(model.icon, .off)
    }

    private final class SilentListener: Listener {
        func send(_ frame: Data) {}
        var pendingFrames: Int { 0 }
        func close() {}
    }
}
