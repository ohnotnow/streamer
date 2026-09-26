import AVFoundation
import XCTest
@testable import Streamer

final class TrackDecoderTests: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = try TestAudio.makeFolder()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    /// A 48 kHz mono file comes out as 44.1 kHz stereo, about one second of it.
    func testConvertsToTheFixedFormat() async throws {
        let url = directory.appendingPathComponent("sine.aiff")
        try TestAudio.writeTone(to: url, seconds: 1, sampleRate: 48000)

        let decoder = try await TrackDecoder(url: url)
        var total: AVAudioFrameCount = 0
        while let buffer = try await decoder.next() {
            XCTAssertEqual(buffer.format, TrackDecoder.pcmFormat)
            total += buffer.frameLength
        }
        XCTAssertEqual(Double(total), 44100, accuracy: 441)
    }

    func testMissingFileThrows() async {
        await assertThrows(try await TrackDecoder(url: directory.appendingPathComponent("nope.mp3")))
    }

    func testNonAudioFileThrows() async throws {
        let url = directory.appendingPathComponent("notes.mp3")
        try Data("not audio".utf8).write(to: url)
        await assertThrows(try await TrackDecoder(url: url))
    }

    private func assertThrows(_ body: @autoclosure () async throws -> TrackDecoder, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("expected an error", line: line)
        } catch {}
    }
}
