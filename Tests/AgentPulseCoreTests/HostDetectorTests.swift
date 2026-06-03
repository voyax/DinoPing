import Testing
@testable import AgentPulseCore

@Suite("HostDetector — executable path → HostKind")
struct HostDetectorTests {

    // MARK: - Terminal apps

    @Test func detectsITerm() {
        #expect(HostDetector.hostKind(forExecutablePath:
            "/Applications/iTerm.app/Contents/MacOS/iTerm2") == .iterm)
    }

    @Test func detectsITerm2BundleName() {
        // Some installs ship the bundle as `iTerm2.app`.
        #expect(HostDetector.hostKind(forExecutablePath:
            "/Applications/iTerm2.app/Contents/MacOS/iTerm2") == .iterm)
    }

    @Test func detectsAppleTerminal() {
        #expect(HostDetector.hostKind(forExecutablePath:
            "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal") == .terminal)
    }

    @Test func detectsGhostty() {
        #expect(HostDetector.hostKind(forExecutablePath:
            "/Applications/Ghostty.app/Contents/MacOS/ghostty") == .ghostty)
    }

    @Test func detectsWarp() {
        #expect(HostDetector.hostKind(forExecutablePath:
            "/Applications/Warp.app/Contents/MacOS/stable") == .warp)
    }

    @Test func detectsWezTerm() {
        #expect(HostDetector.hostKind(forExecutablePath:
            "/Applications/WezTerm.app/Contents/MacOS/wezterm-gui") == .wezterm)
    }

    // MARK: - Editor apps

    @Test func detectsVSCode() {
        #expect(HostDetector.hostKind(forExecutablePath:
            "/Applications/Visual Studio Code.app/Contents/MacOS/Electron") == .vscode)
    }

    @Test func detectsVSCodium() {
        #expect(HostDetector.hostKind(forExecutablePath:
            "/Applications/VSCodium.app/Contents/MacOS/Electron") == .vscode)
    }

    @Test func detectsCursor() {
        #expect(HostDetector.hostKind(forExecutablePath:
            "/Applications/Cursor.app/Contents/MacOS/Cursor") == .cursorApp)
    }

    @Test func detectsZed() {
        #expect(HostDetector.hostKind(forExecutablePath:
            "/Applications/Zed.app/Contents/MacOS/zed") == .zed)
    }

    @Test func detectsZedPreview() {
        #expect(HostDetector.hostKind(forExecutablePath:
            "/Applications/Zed Preview.app/Contents/MacOS/zed") == .zed)
    }

    // MARK: - Non-matches

    @Test func unknownAppIsNil() {
        #expect(HostDetector.hostKind(forExecutablePath:
            "/Applications/SomeRandomApp.app/Contents/MacOS/Foo") == nil)
    }

    @Test func nonAppPathIsNil() {
        // Shell or random binary — no `.app/Contents/MacOS` segment.
        #expect(HostDetector.hostKind(forExecutablePath: "/bin/zsh") == nil)
        #expect(HostDetector.hostKind(forExecutablePath: "/usr/local/bin/claude") == nil)
    }

    @Test func emptyPathIsNil() {
        #expect(HostDetector.hostKind(forExecutablePath: "") == nil)
    }

    @Test func userInstalledAppPath() {
        // Apps installed to ~/Applications instead of /Applications.
        #expect(HostDetector.hostKind(forExecutablePath:
            "/Users/foo/Applications/Ghostty.app/Contents/MacOS/ghostty") == .ghostty)
    }
}

// MARK: - TERM_PROGRAM env detection

@Suite("HostDetector — TERM_PROGRAM env → HostKind")
struct HostDetectorEnvTests {

    @Test func iTermViaEnv() {
        #expect(HostDetector.hostFromEnvironment(["TERM_PROGRAM": "iTerm.app"]) == .iterm)
    }

    @Test func appleTerminalViaEnv() {
        #expect(HostDetector.hostFromEnvironment(["TERM_PROGRAM": "Apple_Terminal"]) == .terminal)
    }

    @Test func ghosttyViaEnv() {
        #expect(HostDetector.hostFromEnvironment(["TERM_PROGRAM": "ghostty"]) == .ghostty)
    }

    @Test func wezTermViaEnv() {
        #expect(HostDetector.hostFromEnvironment(["TERM_PROGRAM": "WezTerm"]) == .wezterm)
    }

    @Test func warpViaEnv() {
        #expect(HostDetector.hostFromEnvironment(["TERM_PROGRAM": "WarpTerminal"]) == .warp)
    }

    @Test func vscodeViaEnv() {
        #expect(HostDetector.hostFromEnvironment([
            "TERM_PROGRAM": "vscode",
            "__CFBundleIdentifier": "com.microsoft.VSCode",
        ]) == .vscode)
    }

    @Test func vscodeInsidersViaEnv() {
        #expect(HostDetector.hostFromEnvironment([
            "TERM_PROGRAM": "vscode",
            "__CFBundleIdentifier": "com.microsoft.VSCodeInsiders",
        ]) == .vscode)
    }

    @Test func cursorViaEnv() {
        // Cursor is a VSCode fork; both set TERM_PROGRAM=vscode but the
        // bundle ID disambiguates.
        #expect(HostDetector.hostFromEnvironment([
            "TERM_PROGRAM": "vscode",
            "__CFBundleIdentifier": "com.todesktop.230313mzl4w4u92",
        ]) == .cursorApp)
    }

    @Test func vscodeForkWithoutBundleFallsBackToVSCode() {
        // Unknown VSCode fork (no bundle ID, or unrecognized) → .vscode
        // is the safer default than nil because TERM_PROGRAM=vscode is
        // a real signal that SOMETHING in the VSCode family is running.
        #expect(HostDetector.hostFromEnvironment([
            "TERM_PROGRAM": "vscode",
        ]) == .vscode)
    }

    @Test func cursorViaIpcHookPath() {
        // Bundle ID missing — fall back to path detection via VSCODE_*
        // env vars that include the .app bundle name.
        #expect(HostDetector.hostFromEnvironment([
            "TERM_PROGRAM": "vscode",
            "VSCODE_IPC_HOOK_CLI": "/Users/foo/Library/Application Support/Cursor/1.2.3-main.sock",
        ]) == .cursorApp)
    }

    @Test func vscodeViaGitAskpassPath() {
        #expect(HostDetector.hostFromEnvironment([
            "TERM_PROGRAM": "vscode",
            "VSCODE_GIT_ASKPASS_NODE": "/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
        ]) == .vscode)
    }

    @Test func unknownTermProgramReturnsNil() {
        // Lets the caller fall back to PID-chain walk.
        #expect(HostDetector.hostFromEnvironment([
            "TERM_PROGRAM": "kitty",
        ]) == nil)
    }

    @Test func missingTermProgramReturnsNil() {
        #expect(HostDetector.hostFromEnvironment([:]) == nil)
        #expect(HostDetector.hostFromEnvironment(["PATH": "/usr/bin"]) == nil)
    }
}

// MARK: - KERN_PROCARGS2 parser

@Suite("HostDetector — parseProcArgs2 buffer parser")
struct HostDetectorParserTests {

    /// Build a buffer in the KERN_PROCARGS2 wire format, then parse it
    /// and assert the extracted env matches.
    private func buildBuffer(argc: Int32, execPath: String, argv: [String], env: [String]) -> [UInt8] {
        var buf: [UInt8] = []
        // 4 bytes argc, little-endian on macOS arm64 (same byte order as host).
        withUnsafeBytes(of: argc) { ptr in
            buf.append(contentsOf: ptr)
        }
        // exec path + \0
        buf.append(contentsOf: execPath.utf8)
        buf.append(0)
        // Word-alignment padding (sometimes present in real buffers; the
        // parser should tolerate any number of \0 bytes between exec path
        // and first argv).
        buf.append(0)
        buf.append(0)
        // argv strings
        for arg in argv {
            buf.append(contentsOf: arg.utf8)
            buf.append(0)
        }
        // env strings
        for e in env {
            buf.append(contentsOf: e.utf8)
            buf.append(0)
        }
        return buf
    }

    @Test func parsesBasicEnv() {
        let buf = buildBuffer(
            argc: 1,
            execPath: "/usr/bin/claude",
            argv: ["claude"],
            env: ["TERM_PROGRAM=Ghostty", "PATH=/usr/bin"]
        )
        let env = HostDetector.parseProcArgs2(buf, size: buf.count)
        #expect(env?["TERM_PROGRAM"] == "Ghostty")
        #expect(env?["PATH"] == "/usr/bin")
    }

    @Test func parsesMultipleArgv() {
        let buf = buildBuffer(
            argc: 3,
            execPath: "/usr/local/bin/node",
            argv: ["node", "/path/to/claude.js", "--no-color"],
            env: ["TERM_PROGRAM=iTerm.app", "FOO=bar"]
        )
        let env = HostDetector.parseProcArgs2(buf, size: buf.count)
        #expect(env?["TERM_PROGRAM"] == "iTerm.app")
        #expect(env?["FOO"] == "bar")
    }

    @Test func parsesValuesWithEquals() {
        // env values containing '=' should preserve them after the first '='.
        let buf = buildBuffer(
            argc: 1,
            execPath: "/bin/sh",
            argv: ["sh"],
            env: ["FOO=a=b=c"]
        )
        let env = HostDetector.parseProcArgs2(buf, size: buf.count)
        #expect(env?["FOO"] == "a=b=c")
    }

    @Test func tooSmallBufferReturnsNil() {
        // Less than 4 bytes (the argc int) can't possibly be valid.
        let env = HostDetector.parseProcArgs2([0x01, 0x02], size: 2)
        #expect(env == nil)
    }
}
