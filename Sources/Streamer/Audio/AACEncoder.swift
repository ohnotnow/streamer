import AVFoundation

/// PCM in `TrackDecoder.pcmFormat`, out as ADTS-framed AAC LC at 192 kbps. One converter for the
/// whole run, never rebuilt at a track change, so the join between tracks is gapless.
///
/// The decoder is async and the converter pulls its input synchronously, so PCM is queued with
/// `append` and `frames()` encodes whatever is queued. An empty queue tells the converter "no data
/// yet", never "end of stream", which would flush it and leave a gap.
final class AACEncoder {
    static let aacFormat: AVAudioFormat = {
        var description = AudioStreamBasicDescription(
            mSampleRate: TrackDecoder.pcmFormat.sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
            mChannelsPerFrame: TrackDecoder.pcmFormat.channelCount, mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &description)!
    }()

    private let converter = AVAudioConverter(from: TrackDecoder.pcmFormat, to: aacFormat)!
    private var queue: [AVAudioPCMBuffer] = []

    init() {
        converter.bitRate = 192_000
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        queue.append(buffer)
    }

    /// Frames of queued PCM not yet handed to the converter.
    var queuedFrames: AVAudioFrameCount {
        queue.reduce(0) { $0 + $1.frameLength }
    }

    /// Every ADTS frame the queued PCM makes. Some PCM stays inside the converter until more arrives.
    func frames() -> [Data] {
        var frames: [Data] = []
        while true {
            let out = AVAudioCompressedBuffer(format: Self.aacFormat, packetCapacity: 16, maximumPacketSize: converter.maximumOutputPacketSize)
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                guard !self.queue.isEmpty else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputStatus.pointee = .haveData
                return self.queue.removeFirst()
            }
            precondition(status != .error, "AAC encoding failed: \(String(describing: error))")
            for i in 0..<Int(out.packetCount) {
                let packet = out.packetDescriptions![i]
                var frame = Data(ADTS.header(payloadLength: Int(packet.mDataByteSize)))
                frame.append(out.data.advanced(by: Int(packet.mStartOffset)).assumingMemoryBound(to: UInt8.self), count: Int(packet.mDataByteSize))
                frames.append(frame)
            }
            if status == .inputRanDry || out.packetCount == 0 { return frames }
        }
    }
}
