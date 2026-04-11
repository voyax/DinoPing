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
        // Try to find the hosting app via the process tree first.
        if let pid = session.pid, pid > 0,
           let hostApp = findHostApp(forPID: pid) {
            hostApp.activate(options: [.activateAllWindows])
            // Try to focus the exact tab/pane via AppleScript (best-effort)
            focusTabForPID(pid, bundleID: hostApp.bundleIdentifier ?? "")
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

    /// Best-effort: use AppleScript to find and focus the tab whose tty
    /// hosts the given PID's process tree.
    private static func focusTabForPID(_ pid: Int, bundleID: String) {
        guard let rawTTY = ttyForPID(pid) else { return }
        // Sanitize tty before embedding in AppleScript to prevent injection
        let tty = rawTTY
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script: String?
        switch bundleID {
        case "com.googlecode.iterm2":
            script = """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s contains "\(tty)" then
                                select t
                                select s
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """
        case "com.apple.Terminal":
            script = """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t contains "\(tty)" then
                            set selected tab of w to t
                            set frontmost of w to true
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """
        default:
            script = nil
        }

        if let script {
            Task.detached {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                proc.arguments = ["-e", script]
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                try? proc.run()
                proc.waitUntilExit()
            }
        }
    }

    /// Find the tty device for a PID by checking /dev/ttys*.
    private static func ttyForPID(_ pid: Int) -> String? {
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-o", "tty=", "-p", "\(pid)"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == true ? nil : String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
