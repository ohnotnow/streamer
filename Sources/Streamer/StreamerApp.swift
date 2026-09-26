import SwiftUI

@main
struct StreamerApp: App {
    @State private var model = AppModel()

    init() {
        if !AppRuntime.isRunningUnitTests { model.loadPlaylists() }
    }

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
