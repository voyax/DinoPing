import Foundation
import Darwin
import os

/// Identifies which terminal / editor application launched a session.
///
/// Strategy (in order):
///
///   1. **Read `TERM_PROGRAM` from the process's initial environment** via
///      `sysctl(KERN_PROCARGS2)`. Every modern macOS terminal sets this
///      env variable when it spawns the user's login shell, and every
///      `fork + exec` along the way (zsh → claude → hooks) inherits it.
///      This is direct, fast, and immune to PID recycling.
///
///   2. **Walk the parent-process chain** as a fallback. Only used when
///      `TERM_PROGRAM` is missing (rare — exotic launchers like cron /
///      launchctl) or has an unknown value. Matches against the same
///      `.app` bundle names as before.
///
/// Approach 1 is the primary path because PID-based walks are fragile:
///   - Dead PIDs get recycled by other processes (often VSCode helpers),
///     leading to false "VSCode" results
///   - `tmux` / `sshd` / `login` break the chain
///   - Sandboxed apps have synthetic parents
///
/// Reading `TERM_PROGRAM` is what apps like fish / oh-my-zsh / Powerline
/// have done for decades to detect the host terminal.
public enum HostDetector {

    // MARK: - Public API

    /// Identify the terminal/editor app that launched the process at `pid`.
    /// Returns nil when neither env nor parent-chain detection can place
    /// the process under a known host.
    public static func detect(for pid: pid_t) -> HostKind? {
        // PRIMARY: read TERM_PROGRAM from the process's initial env.
        if let env = readEnvironment(pid: pid) {
            if let host = hostFromEnvironment(env) {
                let tp = env["TERM_PROGRAM"] ?? "?"
                log.info("pid=\(pid, privacy: .public) TERM_PROGRAM=\(tp, privacy: .public) → \(String(describing: host), privacy: .public)")
                return host
            }
            let tp = env["TERM_PROGRAM"] ?? "missing"
            log.info("pid=\(pid, privacy: .public) TERM_PROGRAM=\(tp, privacy: .public) unrecognized, falling back to PID walk")
        } else {
            log.info("pid=\(pid, privacy: .public) env unreadable (process dead?), falling back to PID walk")
        }

        // FALLBACK: walk parent chain until we hit a known app bundle.
        var cursor = pid
        for _ in 0..<10 {
            guard let parent = parentPID(of: cursor), parent > 1 else {
                log.info("pid=\(pid, privacy: .public) PID walk ended at launchd / unknown")
                return nil
            }
            if let host = matchApp(pid: parent) {
                log.info("pid=\(pid, privacy: .public) PID walk matched ancestor \(parent, privacy: .public) → \(String(describing: host), privacy: .public)")
                return host
            }
            cursor = parent
        }
        log.info("pid=\(pid, privacy: .public) PID walk exhausted without match")
        return nil
    }

    // MARK: - Env-based detection

    /// Read the process's initial env block via sysctl KERN_PROCARGS2.
    /// Returns nil on permission failure or dead PID.
    static func readEnvironment(pid: pid_t) -> [String: String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0

        // First call: query required buffer size.
        if sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) < 0 {
            return nil
        }
        guard size > MemoryLayout<Int32>.size else { return nil }

        // Second call: fill the buffer.
        var buf = [UInt8](repeating: 0, count: size)
        if sysctl(&mib, UInt32(mib.count), &buf, &size, nil, 0) < 0 {
            return nil
        }

        return parseProcArgs2(buf, size: size)
    }

    /// Parse the buffer layout that `KERN_PROCARGS2` produces:
    ///
    ///   ┌─────────────────┬──────────────┬─────────┬──────────────┬──────────────┐
    ///   │ argc  (int32)   │ exec_path\0  │ \0*  pad │ argv strings │ env  strings │
    ///   └─────────────────┴──────────────┴─────────┴──────────────┴──────────────┘
    ///
    /// Each string is null-terminated. After we skip past argc args, every
    /// remaining string is `KEY=VALUE`.
    /// Made internal so unit tests can feed in crafted buffers without
    /// spawning real subprocesses.
    static func parseProcArgs2(_ buf: [UInt8], size: Int) -> [String: String]? {
        let intSize = MemoryLayout<Int32>.size
        guard size >= intSize else { return nil }

        // Read argc.
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { argcPtr in
            buf.withUnsafeBytes { bufPtr in
                memcpy(argcPtr.baseAddress, bufPtr.baseAddress, intSize)
            }
        }

        var idx = intSize

        // Skip exec path (string + terminator + alignment \0 padding).
        while idx < size && buf[idx] != 0 { idx += 1 }
        while idx < size && buf[idx] == 0 { idx += 1 }

        // Skip argc null-terminated args.
        var argsRead: Int32 = 0
        while idx < size && argsRead < argc {
            while idx < size && buf[idx] != 0 { idx += 1 }
            if idx < size { idx += 1 }  // skip terminator
            argsRead += 1
        }

        // Read env strings until end of buffer. Each is "KEY=VALUE".
        var env: [String: String] = [:]
        while idx < size {
            let start = idx
            while idx < size && buf[idx] != 0 { idx += 1 }
            if idx > start {
                let bytes = Array(buf[start..<idx])
                if let str = String(bytes: bytes, encoding: .utf8),
                   let eq = str.firstIndex(of: "=") {
                    let key = String(str[..<eq])
                    let value = String(str[str.index(after: eq)...])
                    env[key] = value
                }
            }
            if idx < size { idx += 1 }
        }

        return env
    }

    /// Map `TERM_PROGRAM` (with `__CFBundleIdentifier` disambiguation
    /// for VSCode-family editors) to a `HostKind`.
    /// Internal for unit testing.
    static func hostFromEnvironment(_ env: [String: String]) -> HostKind? {
        guard let termProgram = env["TERM_PROGRAM"] else { return nil }
        switch termProgram {
        case "iTerm.app":      return .iterm
        case "Apple_Terminal": return .terminal
        case "ghostty":        return .ghostty
        case "WezTerm":        return .wezterm
        case "WarpTerminal":   return .warp
        case "vscode":
            // VSCode + every fork sets TERM_PROGRAM=vscode. Disambiguate
            // primarily via __CFBundleIdentifier, with path-based env
            // fallback for cases where the bundle ID isn't set (rare).
            // Note: Cursor ships through the ToDesktop installer, so its
            // bundle ID is the opaque `com.todesktop.230313mzl4w4u92` —
            // we hardcode it rather than substring-match on "cursor".
            let bundle = env["__CFBundleIdentifier"] ?? ""
            switch bundle {
            case "com.todesktop.230313mzl4w4u92":
                return .cursorApp
            case "com.microsoft.VSCode",
                 "com.microsoft.VSCodeInsiders":
                return .vscode
            default:
                break  // fall through to path-based detection
            }
            // Path-based fallback: any VSCODE_* env value that mentions
            // "cursor" almost certainly comes from Cursor (VSCode's own
            // paths never contain "cursor"). Covers both the .app bundle
            // path (VSCODE_GIT_ASKPASS_NODE points into Cursor.app) and
            // the Application Support socket path (VSCODE_IPC_HOOK_CLI
            // → `~/Library/Application Support/Cursor/...`).
            let cursorPathHints = ["VSCODE_GIT_ASKPASS_NODE", "VSCODE_IPC_HOOK_CLI"]
                .compactMap { env[$0]?.lowercased() }
                .contains { $0.contains("cursor") }
            if cursorPathHints { return .cursorApp }
            // Couldn't disambiguate — `.vscode` is the safer default
            // because TERM_PROGRAM=vscode confirms a VSCode-family host.
            return .vscode
        default:
            return nil
        }
    }

    // MARK: - Parent-chain fallback (unchanged from previous impl)

    private static let PROC_PIDTBSDINFO: Int32 = 3
    private static let PROC_PIDPATHINFO_MAXSIZE: Int = 4 * 1024

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard result > 0 else { return nil }
        return pid_t(info.pbi_ppid)
    }

    private static func matchApp(pid: pid_t) -> HostKind? {
        var buf = [CChar](repeating: 0, count: PROC_PIDPATHINFO_MAXSIZE)
        let count = proc_pidpath(pid, &buf, UInt32(PROC_PIDPATHINFO_MAXSIZE))
        guard count > 0 else { return nil }
        let path = String(cString: buf)
        return Self.hostKind(forExecutablePath: path)
    }

    /// Extract the `.app` name from an absolute executable path and map
    /// to a known `HostKind`. Internal for testing.
    static func hostKind(forExecutablePath path: String) -> HostKind? {
        guard let appRange = path.range(of: ".app/Contents/MacOS") else { return nil }
        let beforeApp = path[..<appRange.lowerBound]
        guard let lastSlash = beforeApp.lastIndex(of: "/") else { return nil }
        let appName = String(beforeApp[beforeApp.index(after: lastSlash)...])
        return appNameMap[appName]
    }

    private static let appNameMap: [String: HostKind] = [
        // Terminals
        "iTerm":               .iterm,
        "iTerm2":              .iterm,
        "Terminal":            .terminal,
        "Ghostty":             .ghostty,
        "Warp":                .warp,
        "WezTerm":             .wezterm,
        // Editors
        "Visual Studio Code":  .vscode,
        "Code":                .vscode,
        "VSCodium":            .vscode,
        "Cursor":              .cursorApp,
        "Zed":                 .zed,
        "Zed Preview":         .zed,
    ]

    // MARK: - Logging

    private static let log = Logger(subsystem: "com.agentpulse.host", category: "HostDetector")
}
