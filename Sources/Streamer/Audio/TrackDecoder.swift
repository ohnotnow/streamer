import AVFoundation

/// Decodes one audio file to PCM, always in `pcmFormat` whatever the file is: the reader does the
/// resampling and channel mixing, so one AAC converter can run across every track unchanged.
final class TrackDecoder {
    enum Failure: Error, Equatable {
        case noAudioTrack
    }

    /// 44.1 kHz, stereo, 16-bit signed, interleaved.
    static let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 2, interleaved: true)!

    private let reader: AVAssetReader
    private let provider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>

    /// Throws if the file is missing, unreadable, or has no audio track.
    nonisolated(nonsending) init(url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw Failure.noAudioTrack
        }
        let format = Self.pcmFormat
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader = try AVAssetReader(asset: asset)
        provider = reader.outputProvider(for: output)
        try reader.start()
    }

    /// The next chunk of PCM, or nil at the end of the track. Throws if decoding fails part way.
    nonisolated(nonsending) func next() async throws -> AVAudioPCMBuffer? {
        guard let sample = try await provider.next() else { return nil }
        let frames = AVAudioFrameCount(sample.sampleCount)
        let buffer = AVAudioPCMBuffer(pcmFormat: Self.pcmFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        let status = sample.withUnsafeSampleBuffer { sampleBuffer in
            CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        }
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return buffer
    }
}
