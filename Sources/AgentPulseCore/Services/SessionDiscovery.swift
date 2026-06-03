import Foundation

/// Discovers running AI agent sessions by scanning processes and transcript files.
public struct SessionDiscovery: Sendable {

    public struct DiscoveredSession: Sendable {
        public let sessionId: String
        public let cwd: String
        public let pid: Int
        public let agentKind: AgentKind
    }

    public init() {}

    /// Discover all active Claude Code sessions.
    public func discoverClaudeCodeSessions() -> [DiscoveredSession] {
        let processes = findAgentProcesses()
        var results: [DiscoveredSession] = []
        var usedSessionIds = Set<String>()

        for proc in processes {
            // Try transcript match, but ensure uniqueness (Fix #9)
            var sessionId = findTranscriptSessionId(forCwd: proc.cwd)

            // If another process already claimed this session ID, fall back to PID-based
            if let sid = sessionId, usedSessionIds.contains(sid) {
                sessionId = nil
            }

            let finalId = sessionId ?? "proc-\(proc.pid)"
            usedSessionIds.insert(finalId)

            results.append(DiscoveredSession(
                sessionId: finalId,
                cwd: proc.cwd,
                pid: proc.pid,
                agentKind: proc.agentKind
            ))
        }

        return results
    }

    /// Cheap liveness probe: the set of currently-live agent PIDs. One
    /// `ps -eo pid,comm` call, NO per-process lsof — safe to poll every few
    /// seconds. Used by the fast death-detection loop. A session whose pid
    /// is absent from this set has exited.
    ///
    /// Returns `nil` when the probe itself failed (spawn error, timeout, or a
    /// truncated listing) — distinct from an empty set, which means "`ps`
    /// succeeded and no agents are running". The caller MUST treat `nil` as
    /// "unknown, skip this tick": a failed probe parsed as an empty set would
    /// mark every tracked session dead and prune the whole count on one bad
    /// poll.
    public func liveAgentPids() -> Set<Int>? {
        guard let output = shell("ps -eo pid,comm", timeout: 5) else { return nil }
        let lines = output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // A healthy `ps -eo pid,comm` lists the entire process table (dozens
        // of lines plus a header). A near-empty result means the probe was
        // killed/timed out before producing real output, not that every
        // process on the machine vanished — signal failure rather than "no
        // agents" so we never prune on a bad poll.
        guard lines.count >= 5 else { return nil }
        var pids = Set<Int>()
        for line in lines {
            for matcher in Self.processMatchers where line.hasSuffix(matcher.suffix) {
                let parts = line.split(separator: " ", maxSplits: 1)
                if let pid = Int(parts.first ?? "") { pids.insert(pid) }
                break
            }
        }
        return pids
    }

    // MARK: - Process Scanning

    private struct AgentProcess {
        let pid: Int
        let cwd: String
        let agentKind: AgentKind
    }

    /// Process name suffixes → AgentKind mapping for all supported agents.
    private static let processMatchers: [(suffix: String, kind: AgentKind)] = [
        ("claude", .claudeCode),
        ("claude-code", .claudeCode),
        ("codex", .codexCLI),
        ("gemini", .geminiCLI),
    ]

    private func findAgentProcesses() -> [AgentProcess] {
        guard let output = shell("ps -eo pid,comm", timeout: 5) else { return [] }

        var results: [AgentProcess] = []
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for matcher in Self.processMatchers {
                if trimmed.hasSuffix(matcher.suffix) {
                    let parts = trimmed.split(separator: " ", maxSplits: 1)
                    if let pid = Int(parts.first ?? "") {
                        if let cwd = cwdForProcess(pid) {
                            results.append(AgentProcess(pid: pid, cwd: cwd, agentKind: matcher.kind))
                        }
                    }
                    break
                }
            }
        }
        return results
    }

    private func cwdForProcess(_ pid: Int) -> String? {
        // Fix #10: add timeout to lsof
        guard let output = shell("lsof -a -p \(pid) -d cwd -Fn 2>/dev/null", timeout: 5) else { return nil }
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("n/") {
                return String(line.dropFirst())
            }
        }
        return nil
    }

    // MARK: - Transcript Matching

    private func findTranscriptSessionId(forCwd cwd: String) -> String? {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        let encodedDir = cwd.replacingOccurrences(of: "/", with: "-")
        let projectDir = claudeDir.appendingPathComponent(encodedDir)

        guard FileManager.default.fileExists(atPath: projectDir.path),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey]
              ) else { return nil }

        let jsonlFiles = files
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> (url: URL, date: Date)? in
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let date = attrs[.modificationDate] as? Date else { return nil }
                return (url, date)
            }
            .sorted { $0.date > $1.date }

        return jsonlFiles.first?.url.deletingPathExtension().lastPathComponent
    }

    // MARK: - Shell (Fix #10: timeout support)

    private func shell(_ command: String, timeout: TimeInterval = 10) -> String? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        // Timeout: kill process if it takes too long. Use a DispatchWorkItem
        // so we can cancel the timeout if the process exits normally first.
        let timeoutItem = DispatchWorkItem { [weak process] in
            if process?.isRunning == true { process?.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutItem.cancel()  // process finished — no need to fire timeout
        return String(data: data, encoding: .utf8)
    }
}
