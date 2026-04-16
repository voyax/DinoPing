import Foundation

/// Typed event that drives SessionState transitions.
/// Derived from HookEvent payloads but decoupled from JSON format.
public enum AgentEvent: Sendable {
    case sessionStarted
    case sessionEnded
    case toolStarted(ToolCall)
    /// `toolUseId` lets the reducer correlate completion with state it set
    /// at PreToolUse time (e.g. clearing a `pendingQuestion` only when the
    /// matching AskUserQuestion completes — not some sibling tool that
    /// happened to finish first).
    case toolSucceeded(toolUseId: String?)
    case toolFailed(reason: String, toolUseId: String?)
    case permissionRequested(PermissionRequest)
    case permissionResolved
    case notified
    case stopped
    case subagentStarted(id: String)
    case subagentStopped
    case userPromptSubmitted
    /// Claude called `AskUserQuestion`. Surfaced via the bridge approval
    /// path, not via a hook event, but flows through the same reducer so
    /// every state mutation has a single entry point.
    case questionAsked(AskUserQuestion, toolUseId: String?)

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
            return .toolSucceeded(toolUseId: p.toolUseId)
        case .postToolUseFailure:
            return .toolFailed(reason: "Tool call failed", toolUseId: p.toolUseId)
        case .permissionRequest:
            // `id` is a fresh UUID, NOT toolUseId — see PermissionRequest doc.
            // Two requests with the same toolUseId (Claude retry, parallel
            // dispatch, etc.) get distinct ids so dedup doesn't drop one.
            let req = PermissionRequest(
                toolUseId: p.toolUseId,
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
        case .userPromptSubmit:
            return .userPromptSubmitted
        }
    }
}
