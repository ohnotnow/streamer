# Technical Overview

Last updated: 2026-09-27

## What This Is

A macOS menubar app that serves a Music playlist, a folder of audio files, or whatever Firefox or Chrome is playing, as one continuous AAC stream at `http://127.0.0.1:8090/stream`.

## Stack

- Swift 6 language mode with strict concurrency, built with Xcode 27 (Swift 6.4 toolchain)
- SwiftUI `MenuBarExtra` for the menu, AppKit for the icon and the open panel
- AVFoundation to decode and encode, Core Audio process taps for live sources, Network.framework for the server, iTunesLibrary for playlists
- No third-party dependencies
- XcodeGen (`project.yml` is the source of truth; `Streamer.xcodeproj` is generated and ignored) and a Makefile
- macOS 27 minimum, because `TrackDecoder` uses the macOS 26+ `AVAssetReader` API and the old one is deprecated on 27

## Directory Structure

```
Sources/Streamer/
  StreamerApp.swift       the menu (SwiftUI MenuBarExtra)
  AppModel.swift          what the menu shows and does; settings in UserDefaults
  MenuBarIcon.swift       the three icon states, drawn in code as a template image
  KeepAwake.swift         idle-sleep assertion while someone listens
  Log.swift, AppRuntime.swift
  Audio/
    Station.swift         Listener and Station protocols, Audience (fan-out, slow-listener rule)
    Broadcaster.swift     plays a track list at real-time pace
    LiveBroadcaster.swift passes on a live feed as it arrives
    ProcessTap.swift      Core Audio process tap: another app's audio, as PCM
    TrackDecoder.swift    one file to PCM
    AACEncoder.swift      PCM to ADTS-framed AAC, one converter for the whole run
    ADTS.swift            the 7-byte ADTS header (pure)
  Server/StreamServer.swift   NWListener, hand-rolled HTTP, ConnectionListener
  Sources/                Source protocol, FolderSource, MusicLibrarySource, LiveSource
Tests/StreamerTests/      XCTest; TestAudio.swift makes tones, folders and PCM buffers
spike/                    throwaway single-file experiments, kept as references
```

## How audio flows

Everything the server and menu touch is a `Station`, so both kinds of source look the same from outside.

```
Track sources (pull, paced by the Mac's clock)

Source.trackURLs() -> TrackDecoder -> AACEncoder -> Broadcaster.tick() -> Audience -> ConnectionListener -> socket
                      (44.1 kHz s16)   (ADTS AAC)   every 20 ms, sends
                                                    what is due + 2 s lead

Live sources (push, paced by the sound hardware)

browser process -> ProcessTap -> LiveBroadcaster.play() -> AACEncoder -> Audience -> ConnectionListener -> socket
                   (float at the output device's rate, resampled to 44.1 kHz s16 on the tap's queue, then handed to the main queue)
```

`TrackDecoder.pcmFormat` (44.1 kHz, stereo, 16-bit interleaved) is the one PCM format the encoder takes, whatever the source.

## Key Types

| Type | Purpose |
|------|---------|
| `Station` | What `StreamServer` and `AppModel` drive: add/remove listeners, stop, listener count, failure. |
| `Audience` | Everyone tuned in to a station. Sends each frame to all, hangs up on anyone more than 10 s behind. Shared by both broadcasters. |
| `Broadcaster` | Walks a `Source`'s tracks in order, looping. Encodes only while someone listens; the last listener leaving pauses it in place. Skips tracks that will not decode; fails if a whole pass plays nothing. |
| `LiveBroadcaster` | Starts its `LiveFeed` on the first listener and stops it on the last. No pause, no skip. Warns after 5 s of pure silence. |
| `ProcessTap` | The real `LiveFeed`: a `CATapDescription` with `mutedWhenTapped` (the app goes quiet at the desk while tapped), read through a private aggregate device. |
| `AACEncoder` | One `AVAudioConverter` for the whole run, fed from a queue. An empty queue means "no data now", never "end of stream", so track changes are gapless. |
| `StreamServer` | `GET /stream` gets `200 audio/aac` and frames until the client goes away; anything else gets 404. Binds 127.0.0.1 unless sharing is on. |
| `AppModel` | Source options (playlists, folders, installed browsers), Start/Stop, status lines, keep-awake. |

## Sources

| Source | Id in `UserDefaults` | Notes |
|--------|------------------------|-------|
| `MusicLibrarySource` | `playlist:<persistent id>` | Read once at launch. Skips items with no local file or with DRM, and counts them. Hides built-in kinds (Movies, Podcasts and so on). |
| `FolderSource` | `folder:<path>` | Recursive, sorted by path, audio extensions only. |
| `LiveSource` | `live:<bundle id>` | Firefox (`org.mozilla.firefox`) and Chrome (`com.google.Chrome`, `com.google.Chrome.helper`), each shown only if installed. Safari is deliberately absent: its audio comes from a shared WebKit process. |

Settings keys: `selectedSource`, `folders`, `sharesOnNetwork`, `keepsAwake`.

## Threading

- Everything that matters runs on the main actor: the model, both broadcasters, the server (its `NWListener` and connections run on the main queue, so handlers use `MainActor.assumeIsolated`).
- `TrackDecoder`'s async methods are `nonisolated(nonsending)`, so they run on the caller's actor.
- The one exception is `ProcessTap`'s IO block, which Core Audio calls on its own thread. It is built in a `nonisolated static` function on purpose: written inline in the `@MainActor` class it inherited main-actor isolation and crashed on the first buffer. It converts there, then hops to the main queue with `DispatchQueue.main.async` (which keeps buffers in order).

## Permissions

| Permission | Needed for | Info.plist key |
|------------|------------|----------------|
| Apple Music | Reading playlists | `NSAppleMusicUsageDescription` |
| Screen & System Audio Recording (audio only) | Live sources | `NSAudioCaptureUsageDescription` |

Both refuse silently, with no prompt, if the key is missing. For audio capture the tap still runs but hears only zeros, and the tapped app is muted anyway. The reason shows only in `tccd`'s log: `log show --last 10m --predicate 'subsystem == "com.apple.TCC"'`. Hardened runtime is on; neither needs an entitlement. No App Sandbox.

Ad-hoc signed builds look like a new app to macOS each time, so `make run` re-asks for permissions. `make install` gives a copy in `/Applications` that keeps its grants, and a `SIGN`/`TEAM` in an untracked `local.mk` signs every build with one certificate.

## Testing

- Framework: XCTest, run with `make test` (`CODE_SIGNING_ALLOWED=NO`).
- Broadcasters are tested with fake listeners; `Broadcaster` takes a fake clock and `ticksAutomatically: false` so tests call `tick()` by hand; `LiveBroadcaster` takes a fake `LiveFeed`.
- Audio comes from `TestAudio`: tones written to temporary AIFF folders, or PCM buffers in `pcmFormat`.
- `AppModel` tests use a throwaway `UserDefaults` suite and port 0, so they pass while the real app is running.
- Not covered by unit tests: `ProcessTap` (needs a real app and the capture permission). Check it by hand: pick a live source, tune in with blether, and listen for the browser going quiet.

## Local Development

```sh
make run        # build and open build/Build/Products/Release/Streamer.app
make install    # build, copy to /Applications, open
make test
make icon       # regenerate the app icon from icon-source.png (needs ImageMagick)
log stream --predicate 'subsystem == "uk.ohnotnow.streamer"'
```

`spike/spike.swift` is the original one-file pipeline, `spike/probe.swift` plays a URL with AVPlayer and reports what it makes of it, and `spike/tap.swift` lists audio processes and records a tap to a WAV file. Each file's header says how to build and run it.
