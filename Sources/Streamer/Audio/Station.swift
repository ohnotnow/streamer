import Foundation

/// Somebody tuned in. The server wraps each connection in one of these.
@MainActor
protocol Listener: AnyObject {
    func send(_ frame: Data)
    /// Frames handed to `send` that have not yet gone out on the wire.
    var pendingFrames: Int { get }
    /// Hang up on this listener.
    func close()
}

/// What the server and the menu drive: a `Broadcaster` playing tracks, or a `LiveBroadcaster`
/// passing on another app's audio as it plays.
@MainActor
protocol Station: AnyObject {
    var listenerCount: Int { get }
    /// Told whenever the number of listeners changes, e.g. to keep the Mac awake.
    var onListenerCountChange: ((Int) -> Void)? { get set }
    /// Set when the station cannot play; it has stopped.
    var failure: String? { get }
    func add(_ listener: any Listener)
    func remove(_ listener: any Listener)
    /// Hang up on everyone and stop for good.
    func stop()
}

/// Everyone tuned in to a station, and the rule for hanging up on anyone who falls too far behind.
@MainActor
struct Audience {
    /// A listener further behind than this is dropped rather than queued for without limit.
    static let slowListenerFrames = Int(10 * Broadcaster.framesPerSecond)

    private var listeners: [ObjectIdentifier: any Listener] = [:]

    var count: Int { listeners.count }
    var isEmpty: Bool { listeners.isEmpty }

    mutating func add(_ listener: any Listener) {
        listeners[ObjectIdentifier(listener)] = listener
    }

    /// False if the listener was not here.
    mutating func remove(_ listener: any Listener) -> Bool {
        listeners.removeValue(forKey: ObjectIdentifier(listener)) != nil
    }

    mutating func closeAll() {
        for listener in listeners.values { listener.close() }
        listeners.removeAll()
    }

    /// Sends one frame to everyone, hanging up on anyone more than 10 s behind.
    mutating func send(_ frame: Data) {
        for listener in Array(listeners.values) {
            listener.send(frame)
            if listener.pendingFrames > Self.slowListenerFrames {
                Log.log("dropping a listener more than 10 s behind")
                listener.close()
                _ = remove(listener)
            }
        }
    }
}
