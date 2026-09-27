# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.8.1] - 2026-09-27

### Fixed
- A live source played slightly fast and high, most noticeable on speech, when the Mac's sound output was a device that runs at 44.1 kHz, such as some Bluetooth headphones.

## [0.8.0] - 2026-09-27

The first tagged release.

### Added
- A macOS menubar app that serves a source as a continuous AAC stream at `http://127.0.0.1:8090/stream`, for blether, VLC, a phone or anything else that plays internet radio.
- Music playlists as a source, after macOS asks for Apple Music access. Tracks with no local file or with DRM are skipped, and the menu says how many.
- Folders as a source, added with "Add folder...": searched all the way down, played in path order, in `mp3`, `m4a` (including ALAC), `aac`, `aiff`, `wav` and `flac`.
- Firefox and Chrome as live sources, passing on whatever the browser is playing. The browser goes quiet on the Mac while someone is listening and plays out loud again when they leave. Safari is not offered.
- A line in the menu when a live source has sent nothing but silence for five seconds, which usually means the browser is paused or audio capture is not allowed.
- Radio-style playback: every listener hears the same audio, tracks play in order and loop, and the stream pauses in place when the last listener leaves.
- Now playing, the listener count and Skip track in the menu.
- "Share on the network", to listen from other devices on the local network or a tailnet, and Copy stream URL with the right host name.
- "Keep Mac awake while listening", on by default.
- A menubar icon that shows off, serving and on air.
- A listener more than 10 seconds behind is dropped, so one slow connection cannot hold the stream up.
- `make install` for a copy in `/Applications`, plus `make run`, `make test` and `make icon`.

[Unreleased]: https://github.com/ohnotnow/streamer/compare/v0.8.1...HEAD
[0.8.1]: https://github.com/ohnotnow/streamer/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/ohnotnow/streamer/releases/tag/v0.8.0
