import Foundation

/// Raw JSON payload from Claude Code hooks. The route determines the event type.
public struct HookPayload: Decodable, Sendable {
    public let sessionId: String
    public let cwd: String
    public let hookEventName: String

    // Tool-related fields (PreToolUse, PostToolUse, PermissionRequest)
    public let toolName: String?
    public let toolInput: [String: AnyCodable]?
    public let toolUseId: String?

    // PostToolUse
    public let toolResult: AnyCodable?

    // Notification
    public let message: String?
    public let title: String?

    // Stop
    public let stopHookActive: Bool?

    // SubagentStart / SubagentStop
    public let agentName: String?
    public let agentDescription: String?
    public let parentSessionId: String?

    // SessionStart
    public let source: String?

    // Memberwise init for test/mock usage
    public init(
        sessionId: String, cwd: String, hookEventName: String,
        toolName: String? = nil, toolInput: [String: AnyCodable]? = nil,
        toolUseId: String? = nil, toolResult: AnyCodable? = nil,
        message: String? = nil, title: String? = nil,
        stopHookActive: Bool? = nil, agentName: String? = nil,
        agentDescription: String? = nil, parentSessionId: String? = nil,
        source: String? = nil
    ) {
        self.sessionId = sessionId; self.cwd = cwd; self.hookEventName = hookEventName
        self.toolName = toolName; self.toolInput = toolInput; self.toolUseId = toolUseId
        self.toolResult = toolResult; self.message = message; self.title = title
        self.stopHookActive = stopHookActive; self.agentName = agentName
        self.agentDescription = agentDescription; self.parentSessionId = parentSessionId
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case hookEventName = "hook_event_name"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case toolUseId = "tool_use_id"
        case toolResult = "tool_result"
        case message, title
        case stopHookActive = "stop_hook_active"
        case agentName = "agent_name"
        case agentDescription = "agent_description"
        case parentSessionId = "parent_session_id"
        case source
    }
}

/// Typed hook event derived from route + payload.
public enum HookEvent: Sendable {
    case sessionStart(HookPayload)
    case sessionEnd(HookPayload)
    case preToolUse(HookPayload)
    case postToolUse(HookPayload)
    case postToolUseFailure(HookPayload)
    case permissionRequest(HookPayload)
    case notification(HookPayload)
    case stop(HookPayload)
    case subagentStart(HookPayload)
    case subagentStop(HookPayload)
    case userPromptSubmit(HookPayload)

    public var payload: HookPayload {
        switch self {
        case .sessionStart(let p), .sessionEnd(let p),
             .preToolUse(let p), .postToolUse(let p), .postToolUseFailure(let p),
             .permissionRequest(let p), .notification(let p), .stop(let p),
             .subagentStart(let p), .subagentStop(let p),
             .userPromptSubmit(let p):
            return p
        }
    }

    public var sessionId: String { payload.sessionId }
}
