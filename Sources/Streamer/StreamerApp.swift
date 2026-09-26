import SwiftUI

@main
struct StreamerApp: App {
    // Loaded here, not in init: reading a @State property in init can hand back a temporary copy,
    // and the playlists went into that copy instead of the model the menu shows (2026-09-26).
    @State private var model: AppModel = {
        let model = AppModel()
        if !AppRuntime.isRunningUnitTests { model.loadPlaylists() }
        return model
    }()

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(!AppRuntime.isRunningUnitTests)) {
            Picker("Source", selection: $model.selectedID) {
                if model.selected == nil { Text("Choose a playlist or folder").tag(String?.none) }
                if !model.playlists.isEmpty {
                    Section("Music playlists") {
                        ForEach(model.playlists) { Text($0.name).tag(String?.some($0.id)) }
                    }
                }
                if !model.folders.isEmpty {
                    Section("Folders") {
                        ForEach(model.folders) { Text($0.name).tag(String?.some($0.id)) }
                    }
                }
            }
            .pickerStyle(.menu)
            .disabled(model.isRunning)
            Button("Add folder...") { addFolder() }
                .disabled(model.isRunning)
            Divider()
            if model.isRunning {
                Button("Stop") { model.stop() }
            } else {
                Button("Start") { Task { await model.start() } }
                    .disabled(model.selected == nil)
            }
            if let broadcaster = model.broadcaster {
                Text("Now playing: \(broadcaster.nowPlaying.map { [$0.artist, $0.title].compactMap { $0 }.joined(separator: ", ") } ?? "starts when someone listens")")
                Text("Listeners: \(broadcaster.listenerCount)")
                Button("Skip track") { broadcaster.skip() }
            }
            Divider()
            Button("Copy stream URL") { model.copyStreamURL() }
            Toggle("Share on the network", isOn: $model.sharesOnNetwork)
                .help("Anyone who can reach this Mac on the network, or your tailnet, can listen. There is no password. Takes effect on the next Start.")
            Toggle("Keep Mac awake while listening", isOn: $model.keepsAwake)
                .help("While someone is listening, this Mac will not go to sleep when idle, like caffeinate -i. The display can still sleep.")
            Divider()
            Button("Quit Streamer") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            // Status lines live below Quit, so a line appearing cannot shift the items above it.
            let status = model.statusLines
            if !status.isEmpty {
                Divider()
                ForEach(status, id: \.self) { line in
                    Button(line) {}.disabled(true)
                }
            }
        } label: {
            Image(nsImage: MenuBarIcon.image(model.icon))
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add folder"
        // Without activating first, the panel opens behind everything under LSUIElement.
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            model.addFolder(url)
        }
    }
}
