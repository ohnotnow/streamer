import Foundation
import iTunesLibrary

/// One playlist from the Music app. Items with no local file (cloud-only) or with DRM are left out
/// and counted, so the menu can say how many were skipped.
struct MusicLibrarySource: Source {
    /// Held so the playlist's items stay loaded.
    let library: ITLibrary
    let playlist: ITLibPlaylist

    var name: String { playlist.name }

    func trackURLs() -> [URL] {
        playable.compactMap(\.location)
    }

    /// Items in the playlist that will not be played.
    var skippedCount: Int {
        playlist.items.count - playable.count
    }

    private var playable: [ITLibMediaItem] {
        playlist.items.filter { $0.location != nil && !$0.isDRMProtected }
    }

    /// Built-in playlists that make no sense as a station (the user's pick, 2026-09-26). Music, the
    /// whole music library, and the smart ones like Recently Added stay.
    static let hiddenKinds: Set<ITLibDistinguishedPlaylistKind> = [
        .kindMovies, .kindTVShows, .kindAudiobooks, .kindRingtones, .kindPodcasts, .kindVoiceMemos,
        .kindiTunesU, .kindMusicVideos, .kindLibraryMusicVideos, .kindHomeVideos, .kindApplications,
        .kindMusicShowsAndMovies,
    ]

    /// The visible playlists in the Music library, in the library's order. The top-level Library
    /// playlist, folders and the built-ins above are left out.
    static func all() throws -> [MusicLibrarySource] {
        let library = try ITLibrary(apiVersion: "1.0")
        return library.allPlaylists
            .filter { $0.isVisible && !$0.isPrimary && $0.kind != .folder && !hiddenKinds.contains($0.distinguishedKind) }
            .map { MusicLibrarySource(library: library, playlist: $0) }
    }
}
