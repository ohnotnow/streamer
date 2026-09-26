import AVFoundation

enum TestAudio {
    /// A 440 Hz tone as a 16-bit AIFF, a format `FolderSource` picks up.
    static func writeTone(to url: URL, seconds: Double, sampleRate: Double = 44100, channels: AVAudioChannelCount = 1) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for i in 0..<Int(frames) {
                buffer.floatChannelData![channel][i] = Float(sin(2 * .pi * 440 * Double(i) / sampleRate) * 0.5)
            }
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true,
        ]
        try AVAudioFile(forWriting: url, settings: settings).write(from: buffer)
    }

    /// A fresh folder in the temporary directory; the caller removes it.
    static func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
