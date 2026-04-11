import Foundation

/// Persistent "always allow" rules. When a user clicks "Always Allow" on a
/// permission card, a rule is saved here. Future permissions matching the
/// rule are auto-approved without showing in the notch.
///
/// Rules are stored in `~/.agentpulse/rules.json` as an array of
/// `AllowRule` objects.
public struct AllowRules: Sendable {
    private static let filePath: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agentpulse/rules.json")
    }()

    public struct AllowRule: Codable, Sendable, Equatable {
        public let toolName: String        // e.g. "Bash", "Edit", "Write"
        public let pattern: String?        // optional glob for command/path
        public let createdAt: Date

        public init(toolName: String, pattern: String? = nil) {
            self.toolName = toolName
            self.pattern = pattern
            self.createdAt = .now
        }
    }

    /// Check if a permission request matches any saved rule.
    public static func isAllowed(toolName: String, toolInput: [String: Any]) -> Bool {
        let rules = load()
        return rules.contains { rule in
            guard rule.toolName == toolName else { return false }
            // If no pattern, matches ALL invocations of this tool
            guard let pattern = rule.pattern else { return true }
            // Match pattern against the primary argument (command for Bash,
            // file_path for Edit/Write/Read)
            let value = primaryArgument(toolName: toolName, input: toolInput)
            return matchGlob(pattern: pattern, value: value)
        }
    }

    /// Save a new rule.
    public static func add(_ rule: AllowRule) {
        var rules = load()
        // Don't duplicate
        guard !rules.contains(rule) else { return }
        rules.append(rule)
        save(rules)
    }

    /// Remove rules matching a tool name.
    public static func remove(toolName: String) {
        var rules = load()
        rules.removeAll { $0.toolName == toolName }
        save(rules)
    }

    /// All current rules.
    public static func load() -> [AllowRule] {
        guard let data = try? Data(contentsOf: filePath),
              let rules = try? JSONDecoder().decode([AllowRule].self, from: data) else {
            return []
        }
        return rules
    }

    private static func save(_ rules: [AllowRule]) {
        let dir = filePath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(rules) {
            try? data.write(to: filePath, options: .atomic)
        }
    }

    /// Extract the primary argument from tool input for pattern matching.
    private static func primaryArgument(toolName: String, input: [String: Any]) -> String {
        switch toolName {
        case "Bash":
            return (input["command"] as? String) ?? ""
        case "Edit", "Write", "Read":
            return (input["file_path"] as? String) ?? ""
        default:
            return ""
        }
    }

    /// Simple glob matching: * matches any sequence, ? matches one char.
    private static func matchGlob(pattern: String, value: String) -> Bool {
        if pattern == "*" { return true }
        let regex = "^" + NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".") + "$"
        return value.range(of: regex, options: .regularExpression) != nil
    }
}
