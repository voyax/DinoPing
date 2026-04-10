import AgentPulseCore
import AppKit
import Foundation

/// Brings whatever terminal-emulator app is running Claude Code to the front.
///
/// Best-effort and intentionally minimal: we don't try to focus a specific
/// tab/pane (the AppleScript surface for that is different in every terminal
/// emulator). The goal is just "get the user out of the notch panel and back
/// to where they were typing", which works as long as we activate the right
/// app — the user's eyes do the rest.
enum TerminalJumper {
    /// Bundle identifiers we recognize as terminal emulators, in priority
    /// order. The first one that's currently running gets activated.
    private static let terminalBundleIDs: [String] = [
        "com.googlecode.iterm2",     // iTerm2
        "com.mitchellh.ghostty",     // Ghostty
        "io.alacritty",              // Alacritty
        "net.kovidgoyal.kitty",      // kitty
        "co.zeit.hyper",             // Hyper
        "dev.warp.Warp-Stable",      // Warp
        "com.apple.Terminal",        // macOS Terminal
    ]

    @MainActor
    static func jump(to session: AgentSession) {
        // Future improvement: walk `session.pid` up the process tree to its
        // controlling terminal and use AppleScript to focus the exact tab.
        // For v1 we just bring the first running terminal app to the front.
        for bundleID in terminalBundleIDs {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            if let app = apps.first {
                app.activate(options: [.activateAllWindows])
                return
            }
        }
        NSSound.beep()  // nothing to jump to
    }
}
