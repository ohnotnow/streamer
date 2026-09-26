import SwiftUI

@main
struct StreamerApp: App {
    var body: some Scene {
        MenuBarExtra(isInserted: .constant(!AppRuntime.isRunningUnitTests)) {
            Button("Quit Streamer") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            // Status lines will go here, below Quit, so a line appearing cannot shift the items above it.
        } label: {
            Image(nsImage: MenuBarIcon.image(.off))
        }
    }
}
