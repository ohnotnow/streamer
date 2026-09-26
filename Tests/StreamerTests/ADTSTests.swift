import XCTest
@testable import Streamer

final class ADTSTests: XCTestCase {
    func testEmptyPayload() {
        XCTAssertEqual(ADTS.header(payloadLength: 0), [0xFF, 0xF1, 0x50, 0x80, 0x00, 0xFF, 0xFC])
    }

    func testTypicalPayload() {
        XCTAssertEqual(ADTS.header(payloadLength: 371), [0xFF, 0xF1, 0x50, 0x80, 0x2F, 0x5F, 0xFC])
    }

    /// 8191 is the largest frame length 13 bits hold, so every length bit is set.
    func testLargestFrame() {
        XCTAssertEqual(ADTS.header(payloadLength: 8184), [0xFF, 0xF1, 0x50, 0x83, 0xFF, 0xFF, 0xFC])
    }

    /// The first frame of a stream the spike served, which ffmpeg and AVPlayer both accepted.
    func testMatchesRealStream() {
        XCTAssertEqual(ADTS.header(payloadLength: 6), [0xFF, 0xF1, 0x50, 0x80, 0x01, 0xBF, 0xFC])
    }
}
