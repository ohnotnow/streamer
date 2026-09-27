import AVFoundation
import Observation

/// Where a live station's audio comes from: a `ProcessTap`, or a fake in tests.
@MainActor
protocol LiveFeed: AnyObject {
    /// Starts handing PCM in `TrackDecoder.pcmFormat` to `deliver`, on the main actor, as it plays.
    func start(deliver: @escaping @MainActor (AVAudioPCMBuffer) -> Void) throws
    func stop()
}

/// Passes on another app's audio as it plays, to every listener at once. Unlike `Broadcaster` it has
/// no clock of its own: the feed pushes audio at the sound hardware's pace and the frames go straight
/// out. The feed runs only while someone is listening, and a new listener hears whatever is playing now.
@MainActor @Observable
final class LiveBroadcaster: Station {
    /// This long of pure silence and the menu says so.
    static let silenceWarningFrames = Int(5 * TrackDecoder.pcmFormat.sampleRate)

    let appName: String
    private(set) var listenerCount = 0 {
        didSet { if listenerCount != oldValue { onListenerCountChange?(listenerCount) } }
    }
    @ObservationIgnored var onListenerCountChange: ((Int) -> Void)?
    /// Set when the feed would not start; the broadcaster has stopped.
    private(set) var failure: String?
    /// Set while the feed has been silent for a while: the app is paused, or macOS is refusing the
    /// capture, which also mutes the app.
    private(set) var warning: String?

    @ObservationIgnored private let feed: any LiveFeed
    @ObservationIgnored private var audience = Audience()
    @ObservationIgnored private let encoder = AACEncoder()
    @ObservationIgnored private var silentFrames = 0

    init(appName: String, feed: any LiveFeed) {
        self.appName = appName
        self.feed = feed
    }

    func add(_ listener: any Listener) {
        guard failure == nil else { return listener.close() }
        audience.add(listener)
        listenerCount = audience.count
        guard audience.count == 1 else { return }
        do {
            try feed.start { [weak self] buffer in self?.play(buffer) }
        } catch {
            Log.log("could not tap \(appName): \(error)")
            failure = "Could not capture \(appName): \(error)"
            stop()
        }
    }

    func remove(_ listener: any Listener) {
        guard audience.remove(listener) else { return }
        audienceChanged()
    }

    func stop() {
        audience.closeAll()
        audienceChanged()
    }

    /// Stops the feed once the last listener has gone.
    private func audienceChanged() {
        listenerCount = audience.count
        guard audience.isEmpty else { return }
        feed.stop()
        silentFrames = 0
        warning = nil
    }

    private func play(_ buffer: AVAudioPCMBuffer) {
        // A buffer already on its way to the main queue when the last listener left.
        guard !audience.isEmpty else { return }
        noteSilence(in: buffer)
        encoder.append(buffer)
        for frame in encoder.frames() { audience.send(frame) }
        audienceChanged()
    }

    private func noteSilence(in buffer: AVAudioPCMBuffer) {
        let samples = UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength * buffer.format.channelCount))
        silentFrames = samples.allSatisfy { $0 == 0 } ? silentFrames + Int(buffer.frameLength) : 0
        let silent = silentFrames >= Self.silenceWarningFrames
        if silent, warning == nil {
            Log.log("nothing but silence from \(appName)")
            warning = "Nothing heard from \(appName). If it is playing, allow Streamer in System Settings, Privacy & Security, Screen & System Audio Recording"
        } else if !silent {
            warning = nil
        }
    }
}
