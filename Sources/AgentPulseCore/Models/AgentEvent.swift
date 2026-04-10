import Foundation

/// Typed event that drives SessionState transitions.
/// Derived from HookEvent payloads but decoupled from JSON format.
public enum AgentEvent: Sendable {
    case sessionStarted
    case sessionEnded
    case toolStarted(ToolCall)
    case toolSucceeded
    case toolFailed(String)
    case permissionRequested(PermissionRequest)
    case permissionResolved
    case notified
    case stopped
    case subagentStarted(id: String)
    case subagentStopped

    /// Convert a HookEvent into an AgentEvent.
    public static func from(_ hook: HookEvent) -> AgentEvent {
        let p = hook.payload
        switch hook {
        case .sessionStart:
            return .sessionStarted
        case .sessionEnd:
            return .sessionEnded
        case .preToolUse:
            let tool = ToolCall(
                id: p.toolUseId ?? UUID().uuidString,
                toolName: p.toolName ?? "Unknown",
                toolInput: p.toolInput ?? [:],
                startTime: .now,
                status: .running
            )
            return .toolStarted(tool)
        case .postToolUse:
            return .toolSucceeded
        case .postToolUseFailure:
            return .toolFailed("Tool call failed")
        case .permissionRequest:
            let req = PermissionRequest(
                id: p.toolUseId ?? "perm-\(UUID().uuidString.prefix(8))",
                sessionId: p.sessionId,
                toolName: p.toolName ?? "Unknown",
                toolInput: p.toolInput ?? [:],
                cwd: p.cwd,
                receivedAt: .now
            )
            return .permissionRequested(req)
        case .notification:
            return .notified
        case .stop:
            return .stopped
        case .subagentStart:
            return .subagentStarted(id: p.sessionId)
        case .subagentStop:
            return .subagentStopped
        }
    }
}
