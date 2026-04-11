import Foundation
import os

/// Installs hook configurations into AI agent config files.
/// - PermissionRequest → command hook (bridge binary, blocking for approval)
/// - All other events → HTTP hooks (non-blocking monitoring)
public struct HookInstaller {
    private let port: Int
    private let bridgePath: String

    /// AgentPulse identifier used to detect our hooks (for cleanup/update).
    private static let hookMarker = "agentpulse"

    public init(port: Int = Constants.defaultPort) {
        self.port = port
        // Bridge binary installed alongside the app
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.bridgePath = "\(home)/.agentpulse/bin/agentpulse-bridge"
    }

    // MARK: - Claude Code

    public func installClaudeCodeHooks() throws {
        // Ensure bridge binary is installed
        try installBridge()

        let settingsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")

        var settings = readJSONFile(settingsPath) ?? [:]
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]

        let baseURL = "http://127.0.0.1:\(port)/hooks"

        // HTTP hooks for monitoring (non-blocking)
        let httpHookConfigs: [(event: String, route: String, timeout: Int)] = [
            ("PreToolUse", "pre-tool-use", 10),
            ("PostToolUse", "post-tool-use", 5),
            ("PostToolUseFailure", "post-tool-use-failure", 5),
            ("Notification", "notification", 5),
            ("SessionStart", "session-start", 5),
            ("SessionEnd", "session-end", 5),
            ("Stop", "stop", 5),
            ("SubagentStart", "subagent-start", 5),
            ("SubagentStop", "subagent-stop", 5),
            ("UserPromptSubmit", "user-prompt-submit", 5),
        ]

        for config in httpHookConfigs {
            let hookEntry: [String: Any] = [
                "type": "http",
                "url": "\(baseURL)/\(config.route)",
                "timeout": config.timeout,
            ]
            mergeHookGroup(into: &hooks, event: config.event, hookEntry: hookEntry)
        }

        // Command hook for PermissionRequest (blocking — bridge waits for notch approval)
        let bridgeHookEntry: [String: Any] = [
            "type": "command",
            "command": "\(bridgePath) --agent claude",
            "timeout": 120,
        ]
        mergeHookGroup(into: &hooks, event: "PermissionRequest", hookEntry: bridgeHookEntry)

        settings["hooks"] = hooks
        try writeJSONFile(settings, to: settingsPath)

        print("[AgentPulse] Claude Code hooks installed (HTTP monitoring + bridge approval)")
    }

    // MARK: - Bridge Binary

    /// Copy the compiled bridge binary to ~/.agentpulse/bin/
    private func installBridge() throws {
        let binDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agentpulse/bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let destURL = binDir.appendingPathComponent("agentpulse-bridge")

        // Find the bridge binary: next to the running executable, or in .build/debug
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("AgentPulseBridge"),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("AgentPulseBridge"),
        ]

        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate.path) {
                try? FileManager.default.removeItem(at: destURL)
                try FileManager.default.copyItem(at: candidate, to: destURL)
                // Ensure executable
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: destURL.path
                )
                print("[AgentPulse] Bridge installed at \(destURL.path)")
                return
            }
        }

        // Fallback: check if already installed
        if FileManager.default.fileExists(atPath: destURL.path) {
            print("[AgentPulse] Bridge already at \(destURL.path)")
            return
        }

        print("[AgentPulse] ⚠️ Bridge binary not found — permission approval via notch won't work")
    }

    // MARK: - Uninstall

    public func uninstall() throws {
        let settingsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")

        guard var settings = readJSONFile(settingsPath),
              var hooks = settings["hooks"] as? [String: Any] else { return }

        let baseURL = "http://127.0.0.1:\(port)/hooks"

        for key in hooks.keys {
            if var groups = hooks[key] as? [[String: Any]] {
                groups.removeAll { group in
                    guard let groupHooks = group["hooks"] as? [[String: Any]] else { return false }
                    return groupHooks.contains { h in
                        let isOurHTTP = (h["url"] as? String)?.hasPrefix(baseURL) ?? false
                        let isOurBridge = (h["command"] as? String)?.contains("agentpulse-bridge") ?? false
                        return isOurHTTP || isOurBridge
                    }
                }
                hooks[key] = groups.isEmpty ? nil : groups
            }
        }

        settings["hooks"] = hooks.isEmpty ? nil : hooks
        try writeJSONFile(settings, to: settingsPath)
        print("[AgentPulse] Hooks uninstalled")
    }

    // MARK: - Private Helpers

    /// Merge a hook entry into the hooks dict, replacing any existing AgentPulse hook for that event.
    private func mergeHookGroup(into hooks: inout [String: Any], event: String, hookEntry: [String: Any]) {
        let baseURL = "http://127.0.0.1:\(port)/hooks"
        let hookGroup: [String: Any] = [
            "matcher": "",
            "hooks": [hookEntry],
        ]

        if var existingGroups = hooks[event] as? [[String: Any]] {
            // Remove existing AgentPulse hooks
            existingGroups.removeAll { group in
                guard let groupHooks = group["hooks"] as? [[String: Any]] else { return false }
                return groupHooks.contains { h in
                    let isOurHTTP = (h["url"] as? String)?.hasPrefix(baseURL) ?? false
                    let isOurBridge = (h["command"] as? String)?.contains("agentpulse-bridge") ?? false
                    return isOurHTTP || isOurBridge
                }
            }
            existingGroups.append(hookGroup)
            hooks[event] = existingGroups
        } else {
            hooks[event] = [hookGroup]
        }
    }

    private func readJSONFile(_ url: URL) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func writeJSONFile(_ json: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
