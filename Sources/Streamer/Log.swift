import os

/// One place to log, readable with `log stream --predicate 'subsystem == "uk.ohnotnow.streamer"'`.
enum Log {
    private static let logger = Logger(subsystem: "uk.ohnotnow.streamer", category: "streamer")

    static func log(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }
}
