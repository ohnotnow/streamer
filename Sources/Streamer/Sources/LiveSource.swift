import AppKit

/// An app whose audio Streamer can pass on as it plays, through a `ProcessTap`.
struct LiveSource {
    let appName: String
    /// Every process the app's audio may come from; the first is the app itself.
    let bundleIDs: [String]

    var name: String { "\(appName) (live)" }

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIDs[0]) != nil
    }

    /// Firefox plays from its main process and Chrome from a helper (checked 2026-09-27). Safari is
    /// left out: it plays from a WebKit process shared with Mail and every other app with a web view,
    /// and nothing ties one of those to Safari.
    static let browsers = [
        LiveSource(appName: "Firefox", bundleIDs: ["org.mozilla.firefox"]),
        LiveSource(appName: "Chrome", bundleIDs: ["com.google.Chrome", "com.google.Chrome.helper"]),
    ]
}
