import Foundation

/// JSON response sent back to Claude Code hooks.
public struct HookResponse: Encodable, Sendable {
    public let hookSpecificOutput: HookSpecificOutput?

    public struct HookSpecificOutput: Encodable, Sendable {
        let hookEventName: String
        let decision: Decision?
        let permissionDecision: String?
        let permissionDecisionReason: String?

        init(
            hookEventName: String,
            decision: Decision? = nil,
            permissionDecision: String? = nil,
            permissionDecisionReason: String? = nil
        ) {
            self.hookEventName = hookEventName
            self.decision = decision
            self.permissionDecision = permissionDecision
            self.permissionDecisionReason = permissionDecisionReason
        }

        public struct Decision: Encodable, Sendable {
            let behavior: String
            let message: String?
        }
    }

    /// For PermissionRequest: allow the tool call
    public static func allow(hookEvent: String) -> HookResponse {
        HookResponse(hookSpecificOutput: .init(
            hookEventName: hookEvent,
            decision: .init(behavior: "allow", message: nil)
        ))
    }

    /// For PermissionRequest: deny the tool call
    public static func deny(hookEvent: String, reason: String) -> HookResponse {
        HookResponse(hookSpecificOutput: .init(
            hookEventName: hookEvent,
            decision: .init(behavior: "deny", message: reason)
        ))
    }

    /// For PreToolUse: allow the tool call (skip permission prompt)
    public static func preToolAllow() -> HookResponse {
        HookResponse(hookSpecificOutput: .init(
            hookEventName: "PreToolUse",
            permissionDecision: "allow",
            permissionDecisionReason: "Approved by AgentPulse"
        ))
    }

    /// For PreToolUse: deny the tool call
    public static func preToolDeny(reason: String) -> HookResponse {
        HookResponse(hookSpecificOutput: .init(
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: reason
        ))
    }

    /// No-op response, proceed normally
    public static let empty = HookResponse(hookSpecificOutput: nil)
}
