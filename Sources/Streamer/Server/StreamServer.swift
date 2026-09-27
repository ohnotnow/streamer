import Foundation
import Network

enum StreamServerError: Error, CustomStringConvertible {
    case timedOut
    case listenFailed(NWError)

    var description: String {
        switch self {
        case .timedOut: "listener did not become ready in time"
        case .listenFailed(let error): "\(error)"
        }
    }
}

/// Serves the broadcaster's frames at `GET /stream`, and 404 for anything else. Loopback only unless
/// `allInterfaces`, which also reaches the tailnet; there is no authentication either way.
/// Everything runs on the main queue, where the station lives.
@MainActor
final class StreamServer {
    static let defaultPort: UInt16 = 8090
    /// A connection that has not sent a whole request by then is dropped.
    static let requestTimeout: TimeInterval = 10

    private let requestedPort: UInt16
    private let allInterfaces: Bool
    private let broadcaster: any Station
    private var listener: NWListener?

    /// The port actually bound, once `start()` has returned. Useful when asking for port 0.
    private(set) var boundPort: UInt16?

    init(port: UInt16 = StreamServer.defaultPort, allInterfaces: Bool = false, broadcaster: any Station) {
        requestedPort = port
        self.allInterfaces = allInterfaces
        self.broadcaster = broadcaster
    }

    /// Binds and waits (at most two seconds) for the listener to be ready. Throws if the port is taken.
    func start() async throws {
        let parameters = NWParameters.tcp
        let port = NWEndpoint.Port(rawValue: requestedPort)!
        let listener: NWListener
        if allInterfaces {
            listener = try NWListener(using: parameters, on: port)
        } else {
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
            listener = try NWListener(using: parameters)
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        self.listener = listener
        do {
            boundPort = try await withCheckedThrowingContinuation { continuation in
                starting = continuation
                listener.stateUpdateHandler = { [weak self] state in
                    MainActor.assumeIsolated {
                        switch state {
                        case .ready: self?.settleStart(.success(listener.port?.rawValue ?? 0))
                        case .failed(let error): self?.settleStart(.failure(.listenFailed(error)))
                        default: break
                        }
                    }
                }
                listener.start(queue: .main)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    MainActor.assumeIsolated { self?.settleStart(.failure(.timedOut)) }
                }
            }
        } catch {
            stop()
            throw error
        }
        Log.log(allInterfaces ? "serving on all interfaces, port \(boundPort!)" : "serving on 127.0.0.1:\(boundPort!)")
    }

    /// `start()` waiting for the listener to be ready or to fail, whichever comes first.
    private var starting: CheckedContinuation<UInt16, any Error>?

    private func settleStart(_ result: Result<UInt16, StreamServerError>) {
        starting?.resume(with: result)
        starting = nil
    }

    /// Stops listening and hangs up on everyone.
    func stop() {
        listener?.cancel()
        listener = nil
        boundPort = nil
        broadcaster.stop()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, buffer: Data())
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.requestTimeout) { [weak self] in
            MainActor.assumeIsolated {
                // Still waiting for its request: nobody has taken it on.
                if connection.state != .cancelled, self?.listeners[ObjectIdentifier(connection)] == nil { connection.cancel() }
            }
        }
    }

    /// Stream listeners by connection, so a connection that goes away can be removed.
    private var listeners: [ObjectIdentifier: ConnectionListener] = [:]

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                let buffer = buffer + (data ?? Data())
                guard let head = buffer.range(of: Data("\r\n\r\n".utf8)).map({ String(decoding: buffer[..<$0.lowerBound], as: UTF8.self) }) else {
                    if error != nil || isComplete || buffer.count > 8192 { connection.cancel() } else { self.receive(connection, buffer: buffer) }
                    return
                }
                self.answer(head, on: connection)
            }
        }
    }

    private func answer(_ head: String, on connection: NWConnection) {
        let requestLine = head.prefix { $0 != "\r" }.split(separator: " ")
        let path = requestLine.count >= 2 ? requestLine[1].split(separator: "?", maxSplits: 1).first.map(String.init) : nil
        guard requestLine.first == "GET", path == "/stream" else {
            let reply = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let reply = "HTTP/1.1 200 OK\r\nContent-Type: audio/aac\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(reply.utf8), completion: .idempotent)
        let listener = ConnectionListener(connection: connection)
        listeners[ObjectIdentifier(connection)] = listener
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.drop(listener)
                default: break
                }
            }
        }
        listener.onFailure = { [weak self] in self?.drop(listener) }
        broadcaster.add(listener)
    }

    private func drop(_ listener: ConnectionListener) {
        guard listeners.removeValue(forKey: ObjectIdentifier(listener.connection)) != nil else { return }
        listener.close()
        broadcaster.remove(listener)
    }
}

/// One tuned-in connection. Counts frames sent but not yet on the wire, so the station can drop
/// a listener that has fallen too far behind.
@MainActor
final class ConnectionListener: Listener {
    let connection: NWConnection
    private(set) var pendingFrames = 0
    var onFailure: (() -> Void)?

    init(connection: NWConnection) {
        self.connection = connection
    }

    func send(_ frame: Data) {
        pendingFrames += 1
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingFrames -= 1
                if error != nil { self.onFailure?() }
            }
        })
    }

    func close() {
        connection.cancel()
    }
}
