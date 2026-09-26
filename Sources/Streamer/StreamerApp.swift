import SwiftUI

@main
struct StreamerApp: App {
    @State private var broadcaster: Broadcaster?
    private let server: StreamServer?

    init() {
        // Temporary until the source picker (streamer-UkLWZ.9): `open Streamer.app --args -folder /path`
        // serves that folder at launch.
        guard !AppRuntime.isRunningUnitTests, let folder = UserDefaults.standard.string(forKey: "folder") else {
            server = nil
            return
        }
        let broadcaster = Broadcaster(source: FolderSource(url: URL(fileURLWithPath: folder)))
        let server = StreamServer(broadcaster: broadcaster)
        Task {
            do { try await server.start() } catch { Log.log("could not serve: \(error)") }
        }
        self.server = server
        _broadcaster = State(initialValue: broadcaster)
    }

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(!AppRuntime.isRunningUnitTests)) {
            if let broadcaster {
                Text("Now playing: \(broadcaster.nowPlaying.map { [$0.artist, $0.title].compactMap { $0 }.joined(separator: ", ") } ?? "nothing")")
                Text("Listeners: \(broadcaster.listenerCount)")
                Button("Skip track") { broadcaster.skip() }
                Divider()
            }
            Button("Quit Streamer") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            // Status lines will go here, below Quit, so a line appearing cannot shift the items above it.
        } label: {
            Image(nsImage: MenuBarIcon.image(icon))
        }
    }

    private var icon: MenuBarIcon.State {
        guard let broadcaster else { return .off }
        return broadcaster.listenerCount > 0 ? .onAir : .ready
    }
}
