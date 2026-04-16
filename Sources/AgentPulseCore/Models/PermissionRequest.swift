import Foundation

public struct PermissionRequest: Identifiable, Sendable {
    /// Unique per-request UUID. Independent from `toolUseId` so that Claude
    /// retrying the same tool call (same toolUseId) produces a *new* request
    /// instead of being silently swallowed by dedup logic that compares
    /// `pendingPermissions` entries by `id`.
    public let id: String
    /// Claude Code's `tool_use_id` from the hook payload. Used by cleanup
    /// logic to match a `PostToolUse`/`PostToolUseFailure` to the request
    /// that it resolves. Optional because some agent / payload variants may
    /// omit it; cleanup degrades gracefully when nil.
    public let toolUseId: String?
    public let sessionId: String
    public let toolName: String
    public let toolInput: [String: AnyCodable]
    public let cwd: String
    public let receivedAt: Date

    public init(
        id: String = UUID().uuidString,
        toolUseId: String?,
        sessionId: String, toolName: String,
        toolInput: [String: AnyCodable], cwd: String, receivedAt: Date
    ) {
        self.id = id
        self.toolUseId = toolUseId
        self.sessionId = sessionId; self.toolName = toolName
        self.toolInput = toolInput; self.cwd = cwd; self.receivedAt = receivedAt
    }

    /// Short title for the tool action
    public var toolTitle: String {
        switch toolName {
        case "Bash": "Bash"
        case "Write": "Write"
        case "Read": "Read"
        case "Edit": "Edit"
        case "Glob": "Search"
        case "Grep": "Grep"
        case "Agent": "Agent"
        default: toolName
        }
    }

    /// File path if applicable
    public var filePath: String? {
        toolInput["file_path"]?.stringValue
    }

    public var fileName: String? {
        guard let path = filePath else { return nil }
        return (path as NSString).lastPathComponent
    }

    /// For Edit: extract old_string and new_string for diff display
    public var diffOldString: String? {
        toolInput["old_string"]?.stringValue
    }

    public var diffNewString: String? {
        toolInput["new_string"]?.stringValue
    }

    /// For Bash: the command
    public var bashCommand: String? {
        toolInput["command"]?.stringValue
    }

    /// For Write: the content
    public var writeContent: String? {
        toolInput["content"]?.stringValue
    }

    /// Whether this request has a code diff to show
    public var hasDiff: Bool {
        toolName == "Edit" && diffOldString != nil && diffNewString != nil
    }

    /// Short one-line description
    public var displayDescription: String {
        switch toolName {
        case "Bash":
            return bashCommand ?? "unknown command"
        case "Write":
            return "Write to \(fileName ?? "?")"
        case "Edit":
            return "\(fileName ?? "?") \(diffSummary)"
        default:
            return "\(toolName)"
        }
    }

    /// e.g. "+4 -3"
    private var diffSummary: String {
        guard let old = diffOldString, let new = diffNewString else { return "" }
        let oldLines = old.components(separatedBy: "\n").count
        let newLines = new.components(separatedBy: "\n").count
        return "+\(newLines) -\(oldLines)"
    }
}

public enum PermissionDecision: Sendable {
    case allow
    case bypass
    case deny(reason: String)
}
