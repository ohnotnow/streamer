// Plays the spike's stream with AVPlayer (what blether uses) and reports what
// AVPlayer makes of it: status, whether the duration is indefinite (live),
// and whether playback time advances.
// Build: swiftc spike/probe.swift -o spike/probe

import AVFoundation

let url = URL(string: CommandLine.arguments.dropFirst().first ?? "http://127.0.0.1:8090/stream")!
let player = AVPlayer(url: url)
player.volume = 0
player.play()

var ticks = 0
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
    ticks += 1
    let item = player.currentItem!
    let duration = item.duration
    print(
        "t=\(ticks * 2)s status=\(item.status.rawValue) control=\(player.timeControlStatus.rawValue)",
        "duration=\(duration.isIndefinite ? "indefinite" : String(duration.seconds))",
        "time=\(String(format: "%.1f", player.currentTime().seconds))",
        "error=\(item.error?.localizedDescription ?? "none")")
    if ticks == 8 { exit(0) }
}
RunLoop.main.run()
