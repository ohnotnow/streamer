import AVFoundation
import XCTest
@testable import Streamer

final class TrackDecoderTests: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    /// A 48 kHz mono file comes out as 44.1 kHz stereo, about one second of it.
    func testConvertsToTheFixedFormat() async throws {
        let url = directory.appendingPathComponent("sine.caf")
        try writeSine(to: url, seconds: 1, sampleRate: 48000, channels: 1)

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

    private func writeSine(to url: URL, seconds: Double, sampleRate: Double, channels: AVAudioChannelCount) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for i in 0..<Int(frames) {
                buffer.floatChannelData![channel][i] = Float(sin(2 * .pi * 440 * Double(i) / sampleRate) * 0.5)
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
