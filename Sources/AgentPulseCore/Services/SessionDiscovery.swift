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

    // MARK: - Process Scanning

    private struct AgentProcess {
        let pid: Int
        let cwd: String
        let agentKind: AgentKind
    }

    private func findAgentProcesses() -> [AgentProcess] {
        guard let output = shell("ps -eo pid,comm", timeout: 5) else { return [] }

        let claudePids = output.components(separatedBy: "\n").compactMap { line -> Int? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasSuffix("claude") || trimmed.hasSuffix("claude-code") else { return nil }
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            return Int(parts.first ?? "")
        }

        return claudePids.compactMap { pid -> AgentProcess? in
            guard let cwd = cwdForProcess(pid) else { return nil }
            return AgentProcess(pid: pid, cwd: cwd, agentKind: .claudeCode)
        }
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
