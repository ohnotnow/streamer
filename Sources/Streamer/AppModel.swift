import AppKit
import Observation
import SystemConfiguration

/// What the menu shows and does: the sources to pick from, Start and Stop, and the settings that
/// survive a restart (added folders, the chosen source, sharing).
@MainActor @Observable
final class AppModel {
    struct SourceOption: Identifiable {
        /// "playlist:<persistent id>" or "folder:<path>", stable across launches.
        let id: String
        let source: any Source
        var name: String { source.name }
    }

    private(set) var playlists: [SourceOption] = []
    private(set) var folders: [SourceOption] = []
    private(set) var broadcaster: Broadcaster?
    /// Set when the Music library could not be read, or the server could not start.
    private(set) var libraryError: String?
    private(set) var serverError: String?

    var selectedID: String? {
        didSet { defaults.set(selectedID, forKey: "selectedSource") }
    }
    var sharesOnNetwork: Bool {
        didSet { defaults.set(sharesOnNetwork, forKey: "sharesOnNetwork") }
    }
    /// Hold off idle sleep while at least one listener is connected. On unless switched off.
    var keepsAwake: Bool {
        didSet {
            defaults.set(keepsAwake, forKey: "keepsAwake")
            updateKeepAwake()
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let port: UInt16
    @ObservationIgnored private var server: StreamServer?
    @ObservationIgnored private let keepAwake = KeepAwake()

    /// `port` 0 lets tests take any free port, so they pass while the real app is running.
    init(defaults: UserDefaults = .standard, port: UInt16 = StreamServer.defaultPort) {
        self.defaults = defaults
        self.port = port
        selectedID = defaults.string(forKey: "selectedSource")
        sharesOnNetwork = defaults.bool(forKey: "sharesOnNetwork")
        keepsAwake = defaults.object(forKey: "keepsAwake") as? Bool ?? true
        folders = (defaults.stringArray(forKey: "folders") ?? []).map(Self.folderOption)
    }

    var isRunning: Bool { broadcaster != nil }

    var selected: SourceOption? {
        (playlists + folders).first { $0.id == selectedID }
    }

    var icon: MenuBarIcon.State {
        guard let broadcaster else { return .off }
        return broadcaster.listenerCount > 0 ? .onAir : .ready
    }

    /// One line each, shown below Quit.
    var statusLines: [String] {
        var lines = [libraryError, serverError, broadcaster?.failure].compactMap { $0 }
        if isRunning, let music = selected?.source as? MusicLibrarySource, music.skippedCount > 0 {
            lines.append("\(music.skippedCount) tracks skipped: no local file, or protected")
        }
        return lines
    }

    /// Reads the Music library's playlists. Called at launch; the list is fixed until the next launch.
    func loadPlaylists() {
        do {
            playlists = try MusicLibrarySource.all().map { SourceOption(id: "playlist:\($0.playlist.persistentID)", source: $0) }
            libraryError = nil
        } catch {
            Log.log("could not read the Music library: \(error)")
            libraryError = "Music playlists unavailable: allow access in System Settings, Privacy & Security, Media & Apple Music"
        }
    }

    func addFolder(_ url: URL) {
        let option = Self.folderOption(url.path)
        if !folders.contains(where: { $0.id == option.id }) {
            folders.append(option)
            defaults.set(folders.map { ($0.source as! FolderSource).url.path }, forKey: "folders")
        }
        selectedID = option.id
    }

    func start() async {
        guard !isRunning, let selected else { return }
        let broadcaster = Broadcaster(source: selected.source)
        let server = StreamServer(port: port, allInterfaces: sharesOnNetwork, broadcaster: broadcaster)
        do {
            try await server.start()
        } catch {
            Log.log("could not serve: \(error)")
            serverError = "Could not listen on port \(port): \(error)"
            return
        }
        serverError = nil
        broadcaster.onListenerCountChange = { [weak self] _ in self?.updateKeepAwake() }
        self.server = server
        self.broadcaster = broadcaster
        Log.log("started \(selected.name)")
    }

    func stop() {
        server?.stop()
        server = nil
        broadcaster = nil
        updateKeepAwake()
    }

    var isKeepingAwake: Bool { keepAwake.isHolding }

    private func updateKeepAwake() {
        keepAwake.hold(keepsAwake && (broadcaster?.listenerCount ?? 0) > 0)
    }

    /// Loopback when sharing is off; the Mac's local network name when it is on.
    var streamURL: String {
        let host = sharesOnNetwork ? Self.localHostName() : "127.0.0.1"
        return "http://\(host):\(port)/stream"
    }

    func copyStreamURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(streamURL, forType: .string)
    }

    private static func folderOption(_ path: String) -> SourceOption {
        SourceOption(id: "folder:\(path)", source: FolderSource(url: URL(fileURLWithPath: path)))
    }

    /// The Bonjour name, e.g. "Mac-mini.local".
    private static func localHostName() -> String {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String? else { return "localhost" }
        return "\(name).local"
    }
}
