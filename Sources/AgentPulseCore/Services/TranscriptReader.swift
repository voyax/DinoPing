import Foundation

/// Reads Claude Code session transcripts (.jsonl files) to extract the latest user prompt.
public struct TranscriptReader: Sendable {

    public init() {}

    /// Returns the most recent user prompt text for a session, or nil if none found.
    /// Looks up `~/.claude/projects/{cwd-encoded}/{sessionId}.jsonl` and scans backward.
    public func latestUserPrompt(cwd: String, sessionId: String) -> String? {
        let url = transcriptURL(cwd: cwd, sessionId: sessionId)
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }

        // Scan lines from the end for the most recent user message
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            if let prompt = extractUserPrompt(from: String(line)) {
                return prompt
            }
        }
        return nil
    }

    /// Resolves the on-disk transcript path for a Claude Code session.
    public func transcriptURL(cwd: String, sessionId: String) -> URL? {
        let encoded = cwd.replacingOccurrences(of: "/", with: "-")
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(encoded)
            .appendingPathComponent("\(sessionId).jsonl")
    }

    // MARK: - Parsing

    /// Extracts user prompt text from one jsonl line. Returns nil if not a real user prompt.
    /// Filters out tool_result messages (those have role=user but are not actual prompts).
    private func extractUserPrompt(from line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Skip non-user entries
        if let type = json["type"] as? String, type != "user" { return nil }

        guard let message = json["message"] as? [String: Any],
              let role = message["role"] as? String, role == "user"
        else { return nil }

        // Content can be a String or an array of content blocks
        if let contentString = message["content"] as? String {
            return cleanPrompt(contentString)
        }

        if let blocks = message["content"] as? [[String: Any]] {
            // Skip if any block is a tool_result — those aren't user prompts
            if blocks.contains(where: { ($0["type"] as? String) == "tool_result" }) {
                return nil
            }
            let text = blocks
                .compactMap { block -> String? in
                    guard (block["type"] as? String) == "text" else { return nil }
                    return block["text"] as? String
                }
                .joined(separator: " ")
            return cleanPrompt(text)
        }

        return nil
    }

    /// Strips wrapper tags Claude Code injects (e.g. <command-name>, <local-command-stdout>, system reminders).
    private func cleanPrompt(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // Drop messages that are entirely command/system wrappers.
        let wrapperPrefixes = [
            "<command-name>", "<local-command-stdout>", "<command-message>",
            "<system-reminder>", "[Request interrupted",
            "[Image: source:", "[Image: original",
        ]
        if wrapperPrefixes.contains(where: { s.hasPrefix($0) }) { return nil }

        // Strip any inline <system-reminder>...</system-reminder> blocks
        while let start = s.range(of: "<system-reminder>"),
              let end = s.range(of: "</system-reminder>", range: start.upperBound..<s.endIndex) {
            s.removeSubrange(start.lowerBound..<end.upperBound)
        }

        // Strip leading image references like "[Image #10]" or "[image #10]"
        // that Claude Code prepends when the user pastes a screenshot — the
        // user's *typed* prompt comes after them.
        s = stripLeadingImageMarkers(s)

        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private func stripLeadingImageMarkers(_ raw: String) -> String {
        var s = raw
        let pattern = #"^\s*\[[Ii]mage\s*#\d+\]\s*"#
        while let range = s.range(of: pattern, options: .regularExpression) {
            s.removeSubrange(range)
        }
        return s
    }
}
