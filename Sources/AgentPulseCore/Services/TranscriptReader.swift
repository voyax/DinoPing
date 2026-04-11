import Foundation

/// Reads Claude Code session transcripts (.jsonl files) to extract the latest user prompt.
public struct TranscriptReader: Sendable {

    /// Max bytes to read from the end of the transcript file.
    private static let tailBytes: UInt64 = 4_194_304  // 4 MB

    /// Max lines to scan backward looking for a user/assistant message.
    private static let scanLimit = 500

    /// Prefixes that mark a message as system-generated (not user-typed).
    private static let wrapperPrefixes = [
        "<command-name>", "<local-command-stdout>", "<command-message>",
        "<system-reminder>", "<task-notification>",
        "<user-prompt-submit-hook>",
        "[Request interrupted",
        "[Image: source:", "[Image: original",
    ]

    /// XML tags that may appear inline and should be stripped.
    private static let inlineTags = [
        "system-reminder", "task-notification", "user-prompt-submit-hook",
    ]

    public init() {}

    /// Returns the most recent user prompt text for a session, or nil if none found.
    /// Looks up `~/.claude/projects/{cwd-encoded}/{sessionId}.jsonl` and scans backward.
    ///
    /// Only reads the last `tailBytes` of the file to keep I/O bounded even
    /// for multi-MB transcripts (called every 5 seconds × N sessions).
    public func latestUserPrompt(cwd: String, sessionId: String) -> String? {
        let url = transcriptURL(cwd: cwd, sessionId: sessionId)
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }

        // Read a generous tail — transcripts with pasted images can have
        // multi-MB base64 lines that push user prompts far from the end.
        // 4 MB handles files up to ~40 MB with heavy image usage.
        let tailBytes = Self.tailBytes
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let fileSize = handle.seekToEndOfFile()
        let offset = fileSize > tailBytes ? fileSize - tailBytes : 0
        handle.seek(toFileOffset: offset)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        // Cap scan depth — active conversations can have hundreds of
        // tool-result lines between user prompts.
        let scanLimit = min(lines.count, Self.scanLimit)
        for i in 0..<scanLimit {
            let line = lines[lines.count - 1 - i]
            // Large lines may contain base64 image data but ALSO the user's
            // typed text. Do a quick substring check before full JSON parse.
            if line.count > 50_000 {
                guard line.contains("\"type\":\"user\"") else { continue }
            }
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

    /// Returns when the transcript file was last modified — a lightweight
    /// proxy for "when was this session last active?" that doesn't require
    /// reading the file contents and updates on every message (user,
    /// assistant, or tool call), not just on hook events.
    public func transcriptModificationDate(cwd: String, sessionId: String) -> Date? {
        guard let url = transcriptURL(cwd: cwd, sessionId: sessionId) else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }

    /// Returns the most recent assistant response text (first ~120 chars).
    /// Uses the same tail-read approach as `latestUserPrompt`.
    public func latestAssistantMessage(cwd: String, sessionId: String) -> String? {
        let url = transcriptURL(cwd: cwd, sessionId: sessionId)
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }

        let tailBytes = Self.tailBytes
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let fileSize = handle.seekToEndOfFile()
        let offset = fileSize > tailBytes ? fileSize - tailBytes : 0
        handle.seek(toFileOffset: offset)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let scanLimit = min(lines.count, Self.scanLimit)
        for i in 0..<scanLimit {
            let line = lines[lines.count - 1 - i]
            if line.count > 50_000 {
                guard line.contains("\"type\":\"assistant\"") else { continue }
            }
            if let msg = extractAssistantText(from: String(line)) {
                return String(msg.prefix(120))
            }
        }
        return nil
    }

    // MARK: - Parsing

    /// Extracts assistant text from one jsonl line. Returns nil if not an assistant message.
    private func extractAssistantText(from line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let type = json["type"] as? String, type != "assistant" { return nil }

        guard let message = json["message"] as? [String: Any],
              let role = message["role"] as? String, role == "assistant"
        else { return nil }

        var raw: String?
        if let blocks = message["content"] as? [[String: Any]] {
            let text = blocks
                .compactMap { block -> String? in
                    guard (block["type"] as? String) == "text" else { return nil }
                    return block["text"] as? String
                }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            raw = text.isEmpty ? nil : text
        } else if let content = message["content"] as? String {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            raw = trimmed.isEmpty ? nil : trimmed
        }

        guard var s = raw else { return nil }

        // Strip markdown formatting for clean display
        s = s.replacingOccurrences(of: #"#{1,6}\s+"#, with: "", options: .regularExpression)  // ## headings
        s = s.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "$1", options: .regularExpression)  // **bold**
        s = s.replacingOccurrences(of: #"\*([^*]+)\*"#, with: "$1", options: .regularExpression)  // *italic*
        s = s.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)  // `code`
        s = s.replacingOccurrences(of: #"^[-*]\s+"#, with: "", options: .regularExpression)  // - list items

        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        // Skip very short / generic replies that add no info
        if s.count < 15 { return nil }

        return s
    }

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

    /// Strips wrapper tags Claude Code injects.
    private func cleanPrompt(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        if Self.wrapperPrefixes.contains(where: { s.hasPrefix($0) }) { return nil }

        // Strip inline XML blocks that Claude Code wraps around user content.
        for tag in Self.inlineTags {
            while let start = s.range(of: "<\(tag)>"),
                  let end = s.range(of: "</\(tag)>", range: start.upperBound..<s.endIndex) {
                s.removeSubrange(start.lowerBound..<end.upperBound)
            }
            // Handle unclosed tags at the end
            if let start = s.range(of: "<\(tag)>") {
                s.removeSubrange(start.lowerBound..<s.endIndex)
            }
        }

        // Strip leading image references like "[Image #10]" or "[Image: ...]"
        s = stripLeadingImageMarkers(s)

        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private func stripLeadingImageMarkers(_ raw: String) -> String {
        var s = raw
        let pattern = #"^\s*\[[Ii]mage\s*[#:][^\]]*\]\s*"#
        while let range = s.range(of: pattern, options: .regularExpression) {
            s.removeSubrange(range)
        }
        return s
    }
}
