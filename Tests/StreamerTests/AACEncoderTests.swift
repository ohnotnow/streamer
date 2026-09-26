import AVFoundation
import XCTest
@testable import Streamer

final class AACEncoderTests: XCTestCase {
    /// About 43 frames a second (44100 / 1024), each a well-formed ADTS frame.
    func testOneSecondMakesWellFormedFrames() {
        let encoder = AACEncoder()
        encoder.append(tone(frames: 44100))
        let frames = encoder.frames()

        XCTAssertEqual(Double(frames.count), 43, accuracy: 3)
        for frame in frames {
            XCTAssertEqual(Array(frame.prefix(2)), [0xFF, 0xF1])
            let length = (Int(frame[3] & 0x03) << 11) | (Int(frame[4]) << 3) | (Int(frame[5]) >> 5)
            XCTAssertEqual(length, frame.count)
        }
        XCTAssertEqual(encoder.queuedFrames, 0)
    }

    /// Two tracks one after the other through the same encoder, with the queue running dry between
    /// them, as it will while the next track's decoder opens.
    func testCarriesOnAcrossTracks() {
        let encoder = AACEncoder()
        encoder.append(tone(frames: 44100))
        let first = encoder.frames()
        XCTAssertEqual(encoder.frames(), [])  // dry: nothing new, and no error
        encoder.append(tone(frames: 44100))
        let second = encoder.frames()

        XCTAssertEqual(Double(first.count + second.count), 86, accuracy: 4)
    }

    /// A continuous tone split in two, with the encoder asked for frames while its queue is empty in
    /// between, decodes back with no silence at the join. This is what gapless track changes rest on.
    func testRunningDryLeavesNoGap() throws {
        let encoder = AACEncoder()
        encoder.append(tone(frames: 22050, startingAt: 0))
        var frames = encoder.frames()
        frames += encoder.frames()
        encoder.append(tone(frames: 22050, startingAt: 22050))
        frames += encoder.frames()
        encoder.append(tone(frames: 22050, startingAt: 44100))  // pushes the join out of the converter
        frames += encoder.frames()

        let samples = try decode(frames)
        // Skip the encoder's priming at the start; everything after should be tone, never a silent run.
        let body = samples.dropFirst(4096)
        XCTAssertGreaterThan(body.count, 44100)
        XCTAssertLessThan(longestQuietRun(body), 64, "a run of silence means the join was not gapless")
    }

    // MARK: Helpers

    private func tone(frames: AVAudioFrameCount, startingAt start: Int = 0) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: TrackDecoder.pcmFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.int16ChannelData![0]
        for i in 0..<Int(frames) {
            let value = Int16(sin(2 * .pi * 440 * Double(start + i) / 44100) * 16000)
            samples[2 * i] = value
            samples[2 * i + 1] = value
        }
        return buffer
    }

    /// ADTS frames back to mono Float samples (the left channel), with Apple's AAC decoder.
    private func decode(_ frames: [Data]) throws -> [Float] {
        let pcm = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let decoder = try XCTUnwrap(AVAudioConverter(from: AACEncoder.aacFormat, to: pcm))
        var pending = frames.map { $0.dropFirst(ADTS.headerLength) }
        var samples: [Float] = []
        while true {
            let out = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 4096)!
            var error: NSError?
            let status = decoder.convert(to: out, error: &error) { _, inputStatus in
                guard let payload = pending.first else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                pending.removeFirst()
                let packet = AVAudioCompressedBuffer(format: AACEncoder.aacFormat, packetCapacity: 1, maximumPacketSize: payload.count)
                payload.copyBytes(to: packet.data.assumingMemoryBound(to: UInt8.self), count: payload.count)
                packet.packetDescriptions![0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(payload.count))
                packet.packetCount = 1
                packet.byteLength = UInt32(payload.count)
                inputStatus.pointee = .haveData
                return packet
            }
            if status == .error { throw try XCTUnwrap(error) }
            samples += UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))
            if status == .endOfStream || out.frameLength == 0 { return samples }
        }
    }

    private func longestQuietRun(_ samples: ArraySlice<Float>) -> Int {
        var longest = 0, run = 0
        for sample in samples {
            run = abs(sample) < 0.01 ? run + 1 : 0
            longest = max(longest, run)
        }
        return longest
    }
}
