import AVFoundation
import Observation

/// Somebody tuned in. The server wraps each connection in one of these.
@MainActor
protocol Listener: AnyObject {
    func send(_ frame: Data)
    /// Frames handed to `send` that have not yet gone out on the wire.
    var pendingFrames: Int { get }
    /// Hang up on this listener.
    func close()
}

/// Walks a source's tracks in order, looping, and sends the same ADTS frames to every listener at
/// real-time pace. Encodes only while someone is listening; the last one leaving pauses it where it
/// is, and the next listener picks up from there.
@MainActor @Observable
final class Broadcaster {
    struct Track: Equatable {
        let url: URL
        let artist: String?
        let title: String
    }

    static let framesPerSecond = TrackDecoder.pcmFormat.sampleRate / 1024
    /// Sent ahead of real time so a new listener's player fills its buffer quickly.
    static let leadSeconds = 2.0
    /// A listener further behind than this is dropped rather than queued for without limit.
    static let slowListenerFrames = Int(10 * framesPerSecond)

    private(set) var nowPlaying: Track?
    private(set) var listenerCount = 0 {
        didSet { if listenerCount != oldValue { onListenerCountChange?(listenerCount) } }
    }
    /// Told whenever the number of listeners changes, e.g. to keep the Mac awake.
    @ObservationIgnored var onListenerCountChange: ((Int) -> Void)?
    /// Set when the source has nothing that will play; the broadcaster has stopped.
    private(set) var failure: String?

    @ObservationIgnored private let source: any Source
    @ObservationIgnored private let now: () -> TimeInterval
    @ObservationIgnored private let ticksAutomatically: Bool
    @ObservationIgnored private var listeners: [ObjectIdentifier: any Listener] = [:]
    @ObservationIgnored private var tracks: [URL] = []
    @ObservationIgnored private var trackIndex = -1
    @ObservationIgnored private var decoder: TrackDecoder?
    @ObservationIgnored private let encoder = AACEncoder()
    @ObservationIgnored private var pending: [Data] = []
    @ObservationIgnored private var startedAt: TimeInterval = 0
    @ObservationIgnored private var framesSent = 0
    @ObservationIgnored private var ticking = false
    @ObservationIgnored private var loop: Task<Void, Never>?

    /// `now` and `ticksAutomatically` are for tests: a fake clock, and calling `tick()` by hand.
    init(source: any Source, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, ticksAutomatically: Bool = true) {
        self.source = source
        self.now = now
        self.ticksAutomatically = ticksAutomatically
    }

    func add(_ listener: any Listener) {
        guard failure == nil else { return listener.close() }
        listeners[ObjectIdentifier(listener)] = listener
        listenerCount = listeners.count
        if listeners.count == 1 { resume() }
    }

    func remove(_ listener: any Listener) {
        guard listeners.removeValue(forKey: ObjectIdentifier(listener)) != nil else { return }
        listenerCount = listeners.count
        if listeners.isEmpty { pause() }
    }

    /// Moves on to the next track. Listeners hear the change once the frames already sent have played.
    func skip() {
        decoder = nil
        encoder.discardQueued()
        pending.removeAll()
    }

    /// Hang up on everyone and stop for good.
    func stop() {
        for listener in listeners.values { listener.close() }
        listeners.removeAll()
        listenerCount = 0
        pause()
    }

    /// Sends whatever is due. The loop calls this every 20 ms while anyone is listening.
    func tick() async {
        guard !ticking, !listeners.isEmpty else { return }
        ticking = true
        defer { ticking = false }
        let due = Int((now() - startedAt + Self.leadSeconds) * Self.framesPerSecond)
        while framesSent < due, !listeners.isEmpty {
            guard let frame = await nextFrame() else { return }
            for listener in Array(listeners.values) {
                listener.send(frame)
                if listener.pendingFrames > Self.slowListenerFrames {
                    Log.log("dropping a listener more than 10 s behind")
                    listener.close()
                    remove(listener)
                }
            }
            framesSent += 1
        }
    }

    private func resume() {
        startedAt = now()
        framesSent = 0
        guard ticksAutomatically else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func pause() {
        loop?.cancel()
        loop = nil
    }

    /// The next ADTS frame, decoding and changing track as needed. Nil means nothing will play.
    private func nextFrame() async -> Data? {
        while pending.isEmpty {
            // Keep a little PCM queued so the converter always has something to pull.
            while encoder.queuedFrames < 4096 {
                guard await feedEncoder() else { return nil }
            }
            pending = encoder.frames()
        }
        return pending.removeFirst()
    }

    /// Queues one more chunk of PCM, moving to the next track at the end of this one. Returns false,
    /// having stopped with a failure, if a whole pass of the source played nothing.
    private func feedEncoder() async -> Bool {
        var failuresInARow = 0
        while true {
            if let decoder {
                do {
                    if let buffer = try await decoder.next() {
                        encoder.append(buffer)
                        return true
                    }
                } catch {
                    Log.log("stopped part way through \(nowPlaying?.url.lastPathComponent ?? "a track"): \(error)")
                }
                self.decoder = nil
            }
            if trackIndex + 1 >= tracks.count {
                tracks = (try? source.trackURLs()) ?? []
                trackIndex = -1
            }
            guard !tracks.isEmpty, failuresInARow < tracks.count else {
                fail("Nothing in \(source.name) will play")
                return false
            }
            trackIndex += 1
            let url = tracks[trackIndex]
            do {
                decoder = try await TrackDecoder(url: url)
                nowPlaying = await Self.track(at: url)
                failuresInARow = 0
            } catch {
                Log.log("skipping \(url.lastPathComponent): \(error)")
                failuresInARow += 1
            }
        }
    }

    private func fail(_ message: String) {
        Log.log(message)
        failure = message
        nowPlaying = nil
        stop()
    }

    /// Artist and title from the file's tags, falling back to the file name for the title.
    private static func track(at url: URL) async -> Track {
        let metadata = (try? await AVURLAsset(url: url).load(.commonMetadata)) ?? []
        func string(_ key: AVMetadataKey) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: metadata, withKey: key, keySpace: .common).first else { return nil }
            return try? await item.load(.stringValue)
        }
        let title = await string(.commonKeyTitle) ?? url.deletingPathExtension().lastPathComponent
        return Track(url: url, artist: await string(.commonKeyArtist), title: title)
    }
}
