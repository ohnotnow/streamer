import AVFoundation
import XCTest
@testable import Streamer

@MainActor
final class LiveBroadcasterTests: XCTestCase {
    /// The feed runs only while someone is listening, so the app is heard at the desk otherwise.
    func testFeedRunsOnlyWhileSomeoneListens() {
        let feed = FakeFeed()
        let broadcaster = LiveBroadcaster(appName: "Firefox", feed: feed)
        XCTAssertFalse(feed.running)

        let a = FakeListener(), b = FakeListener()
        broadcaster.add(a)
        broadcaster.add(b)
        XCTAssertTrue(feed.running)
        XCTAssertEqual(feed.starts, 1)
        broadcaster.remove(a)
        XCTAssertTrue(feed.running)
        broadcaster.remove(b)
        XCTAssertFalse(feed.running)
        XCTAssertEqual(broadcaster.listenerCount, 0)
    }

    func testEveryListenerHearsWhatTheFeedPlays() {
        let feed = FakeFeed()
        let broadcaster = LiveBroadcaster(appName: "Firefox", feed: feed)
        let a = FakeListener(), b = FakeListener()
        broadcaster.add(a)
        broadcaster.add(b)
        feed.play(TestAudio.pcmBuffer(seconds: 1))
        // The encoder keeps a frame or two back until more arrives.
        XCTAssertEqual(Double(a.frames.count), Broadcaster.framesPerSecond, accuracy: 3)
        XCTAssertEqual(a.frames, b.frames)
    }

    func testAFeedThatWillNotStartStopsTheStation() {
        let feed = FakeFeed()
        feed.startError = ProcessTap.Failure.coreAudio("Creating the tap", -1)
        let broadcaster = LiveBroadcaster(appName: "Firefox", feed: feed)
        let listener = FakeListener()
        broadcaster.add(listener)
        XCTAssertNotNil(broadcaster.failure)
        XCTAssertTrue(listener.closed)
        XCTAssertEqual(broadcaster.listenerCount, 0)
    }

    /// Pure silence for a while means the app is paused, or macOS is refusing the capture.
    func testWarnsAfterAWhileOfPureSilence() {
        let feed = FakeFeed()
        let broadcaster = LiveBroadcaster(appName: "Firefox", feed: feed)
        broadcaster.add(FakeListener())
        for _ in 0..<4 { feed.play(TestAudio.pcmBuffer(seconds: 1, silent: true)) }
        XCTAssertNil(broadcaster.warning)
        for _ in 0..<2 { feed.play(TestAudio.pcmBuffer(seconds: 1, silent: true)) }
        XCTAssertNotNil(broadcaster.warning)
        feed.play(TestAudio.pcmBuffer(seconds: 0.1))
        XCTAssertNil(broadcaster.warning)
    }

    // MARK: Helpers

    final class FakeFeed: LiveFeed {
        var running = false
        var starts = 0
        var startError: Error?
        private var deliver: ((AVAudioPCMBuffer) -> Void)?

        func start(deliver: @escaping @MainActor (AVAudioPCMBuffer) -> Void) throws {
            if let startError { throw startError }
            running = true
            starts += 1
            self.deliver = deliver
        }

        func stop() {
            running = false
            deliver = nil
        }

        func play(_ buffer: AVAudioPCMBuffer) { deliver?(buffer) }
    }

    final class FakeListener: Listener {
        var frames: [Data] = []
        var closed = false
        func send(_ frame: Data) { frames.append(frame) }
        var pendingFrames: Int { 0 }
        func close() { closed = true }
    }
}
