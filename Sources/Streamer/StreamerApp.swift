import SwiftUI

@main
struct StreamerApp: App {
    @State private var broadcaster: Broadcaster?
    private let server: StreamServer?

    init() {
        // Temporary until the source picker (streamer-UkLWZ.9): `open Streamer.app --args -folder /path`
        // or `--args -playlist "Name"` serves that folder or Music playlist at launch.
        guard !AppRuntime.isRunningUnitTests, let source = Self.launchSource() else {
            server = nil
            return
        }
        let broadcaster = Broadcaster(source: source)
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

    private static func launchSource() -> (any Source)? {
        let defaults = UserDefaults.standard
        if let folder = defaults.string(forKey: "folder") {
            return FolderSource(url: URL(fileURLWithPath: folder))
        }
        guard let name = defaults.string(forKey: "playlist") else { return nil }
        do {
            let playlists = try MusicLibrarySource.all()
            Log.log("Music library: \(playlists.count) playlists")
            guard let playlist = playlists.first(where: { $0.name == name }) else {
                Log.log("no playlist called \(name)")
                return nil
            }
            Log.log("playing \(name): \(playlist.trackURLs().count) tracks, \(playlist.skippedCount) skipped")
            return playlist
        } catch {
            Log.log("could not read the Music library: \(error)")
            return nil
        }
    }

    private var icon: MenuBarIcon.State {
        guard let broadcaster else { return .off }
        return broadcaster.listenerCount > 0 ? .onAir : .ready
    }
}
