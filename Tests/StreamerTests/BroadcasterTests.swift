import XCTest
@testable import Streamer

@MainActor
final class BroadcasterTests: XCTestCase {
    /// About 43 frames a second of audio.
    let perSecond = Broadcaster.framesPerSecond

    func testSendsNothingUntilSomeoneListens() async throws {
        let (broadcaster, clock) = try makeBroadcaster(tracks: [("1 One", 3)])
        await broadcaster.tick()
        XCTAssertEqual(broadcaster.nowPlaying, nil)

        let listener = FakeListener()
        broadcaster.add(listener)
        await broadcaster.tick()
        XCTAssertEqual(Double(listener.frames.count), 2 * perSecond, accuracy: 1)  // the lead

        clock.time += 1
        await broadcaster.tick()
        XCTAssertEqual(Double(listener.frames.count), 3 * perSecond, accuracy: 1)  // lead plus a second
    }

    func testLastListenerLeavingPausesAndTheNextResumesInPlace() async throws {
        let (broadcaster, clock) = try makeBroadcaster(tracks: [("1 One", 4), ("2 Two", 4), ("3 Three", 4)])
        let first = FakeListener()
        broadcaster.add(first)
        clock.time += 3  // lead plus three seconds: five seconds in, so into the second track
        await broadcaster.tick()
        XCTAssertEqual(broadcaster.nowPlaying?.title, "2 Two")

        broadcaster.remove(first)
        clock.time += 60
        await broadcaster.tick()
        let sentWhileEmpty = first.frames.count
        XCTAssertEqual(broadcaster.listenerCount, 0)

        let second = FakeListener()
        broadcaster.add(second)
        await broadcaster.tick()
        XCTAssertEqual(first.frames.count, sentWhileEmpty)
        XCTAssertEqual(broadcaster.nowPlaying?.title, "2 Two")  // seven seconds in with the new lead: still the second track
        XCTAssertEqual(Double(second.frames.count), 2 * perSecond, accuracy: 1)  // a fresh lead, not a minute's backlog
    }

    /// Skipping moves to the next track without disturbing the pace.
    func testSkipMovesToTheNextTrack() async throws {
        let (broadcaster, clock) = try makeBroadcaster(tracks: [("1 One", 10), ("2 Two", 10)])
        let listener = FakeListener()
        broadcaster.add(listener)
        await broadcaster.tick()
        XCTAssertEqual(broadcaster.nowPlaying?.title, "1 One")

        broadcaster.skip()
        clock.time += 1
        await broadcaster.tick()
        XCTAssertEqual(broadcaster.nowPlaying?.title, "2 Two")
        XCTAssertEqual(Double(listener.frames.count), 3 * perSecond, accuracy: 1)
    }

    func testEveryListenerHearsTheSameFrames() async throws {
        let (broadcaster, clock) = try makeBroadcaster(tracks: [("1 One", 3)])
        let a = FakeListener(), b = FakeListener()
        broadcaster.add(a)
        broadcaster.add(b)
        clock.time += 0.5
        await broadcaster.tick()
        XCTAssertFalse(a.frames.isEmpty)
        XCTAssertEqual(a.frames, b.frames)
    }

    func testSkipsATrackThatWillNotPlay() async throws {
        let (broadcaster, clock) = try makeBroadcaster(tracks: [("1 One", 1), ("2 Broken", nil), ("3 Three", 1)])
        let listener = FakeListener()
        listener.onSend = { listener.titles.insert(broadcaster.nowPlaying?.title ?? "") }
        broadcaster.add(listener)
        clock.time += 1
        await broadcaster.tick()
        XCTAssertEqual(listener.titles, ["1 One", "3 Three"])
        XCTAssertNil(broadcaster.failure)
    }

    func testStopsWhenNothingWillPlay() async throws {
        let (broadcaster, _) = try makeBroadcaster(tracks: [("1 Broken", nil), ("2 Broken", nil)])
        let listener = FakeListener()
        broadcaster.add(listener)
        await broadcaster.tick()
        XCTAssertNotNil(broadcaster.failure)
        XCTAssertTrue(listener.closed)
        XCTAssertEqual(broadcaster.listenerCount, 0)
    }

    func testDropsAListenerThatCannotKeepUp() async throws {
        let (broadcaster, clock) = try makeBroadcaster(tracks: [("1 One", 15)])
        let slow = FakeListener(drains: false), healthy = FakeListener()
        broadcaster.add(slow)
        broadcaster.add(healthy)
        clock.time += 12
        await broadcaster.tick()
        XCTAssertTrue(slow.closed)
        XCTAssertEqual(slow.frames.count, Broadcaster.slowListenerFrames + 1)
        XCTAssertFalse(healthy.closed)
        XCTAssertEqual(Double(healthy.frames.count), 14 * perSecond, accuracy: 1)
        XCTAssertEqual(broadcaster.listenerCount, 1)
    }

    // MARK: Helpers

    final class Clock { var time: TimeInterval = 1000 }

    final class FakeListener: Listener {
        let drains: Bool
        var frames: [Data] = []
        var closed = false
        var titles: Set<String> = []
        var onSend: (() -> Void)?
        init(drains: Bool = true) { self.drains = drains }
        func send(_ frame: Data) { frames.append(frame); onSend?() }
        var pendingFrames: Int { drains ? 0 : frames.count }
        func close() { closed = true }
    }

    /// A folder of tones, one per (title, seconds); a nil length writes a file that will not decode.
    private func makeBroadcaster(tracks: [(String, Double?)]) throws -> (Broadcaster, Clock) {
        let folder = try TestAudio.makeFolder()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        for (title, seconds) in tracks {
            let url = folder.appendingPathComponent(title).appendingPathExtension("aiff")
            if let seconds { try TestAudio.writeTone(to: url, seconds: seconds) } else { try Data("not audio".utf8).write(to: url) }
        }
        let clock = Clock()
        return (Broadcaster(source: FolderSource(url: folder), now: { clock.time }, ticksAutomatically: false), clock)
    }
}
