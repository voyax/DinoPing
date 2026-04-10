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
    /// Bundle identifiers we recognize as hosts for AI agent sessions.
    /// Includes standalone terminals AND editors with integrated terminals.
    /// The first one that's currently running gets activated.
    private static let terminalBundleIDs: [String] = [
        // Standalone terminals
        "com.googlecode.iterm2",     // iTerm2
        "com.mitchellh.ghostty",     // Ghostty
        "io.alacritty",              // Alacritty
        "net.kovidgoyal.kitty",      // kitty
        "co.zeit.hyper",             // Hyper
        "dev.warp.Warp-Stable",      // Warp
        "com.apple.Terminal",        // macOS Terminal
        // Editors with integrated terminals (Claude Code / Codex can run here)
        "com.microsoft.VSCode",      // VS Code
        "com.todesktop.230313mzl4w4u92", // Cursor
        "dev.zed.Zed",               // Zed
    ]

    @MainActor
    static func jump(to session: AgentSession) {
        // Try to find the hosting app via the process tree first. If the
        // session has a PID, walk up to find a GUI parent that matches one
        // of our known terminal/editor bundle IDs.
        if let pid = session.pid, pid > 0,
           let hostApp = findHostApp(forPID: pid) {
            hostApp.activate(options: [.activateAllWindows])
            return
        }

        // Fallback: activate the first known terminal/editor that's running.
        for bundleID in terminalBundleIDs {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                app.activate(options: [.activateAllWindows])
                return
            }
        }
        NSSound.beep()
    }

    /// Walk the process tree from `pid` upward, looking for a parent whose
    /// bundle ID is one we recognize. Returns the NSRunningApplication if
    /// found, nil otherwise.
    private static func findHostApp(forPID pid: Int) -> NSRunningApplication? {
        var current = Int32(pid)
        var visited = Set<Int32>()

        while current > 1, !visited.contains(current) {
            visited.insert(current)
            // Check if this PID matches a known running app
            if let app = NSRunningApplication(processIdentifier: current),
               let bundleID = app.bundleIdentifier,
               terminalBundleIDs.contains(bundleID) {
                return app
            }
            // Move to parent
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { break }
            let ppid = info.kp_eproc.e_ppid
            if ppid == current { break }
            current = ppid
        }
        return nil
    }
}
