import Foundation

/// Holds off idle system sleep, the same as `caffeinate -i`: the display can still sleep. Shows in
/// `pmset -g assertions` under Streamer with its reason.
@MainActor
final class KeepAwake {
    private var activity: (any NSObjectProtocol)?

    var isHolding: Bool { activity != nil }

    func hold(_ wanted: Bool) {
        if wanted, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled, reason: "Streaming to listeners")
        } else if !wanted, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
