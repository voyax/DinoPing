import Foundation

public extension DinoState {

    /// Map a single session's runtime state to its dino state.
    ///
    /// Priority (top wins):
    /// 1. Pending permission OR pending question → `.action` — agent is
    ///    blocked waiting for the human, regardless of `status` value.
    /// 2. `status == .active` → `.running`.
    /// 3. Everything else (idle, done, stopped, waitingForInput) → `.dormant`.
    ///
    /// Note: `.waitingForPermission` *should* always coexist with a non-nil
    /// `pendingPermission`, but we map it to `.action` defensively in case
    /// the two get out of sync during a transient state update.
    static func from(_ session: AgentSession) -> DinoState {
        if session.pendingPermission != nil { return .action }
        if session.pendingQuestion != nil   { return .action }
        switch session.status {
        case .active:               return .running
        case .waitingForPermission: return .action
        case .waitingForInput, .idle, .done, .stopped:
            return .dormant
        }
    }

    /// App-wide aggregate state across all live sessions.
    /// - any session in `.action` → `.action` (highest priority — short-circuits)
    /// - any session in `.running` → `.running`
    /// - else → `.dormant`
    ///
    /// `.expanded` is a UI mode (user opened the notch), not derived from
    /// session state, so it's never returned here.
    static func aggregate(from sessions: some Sequence<AgentSession>) -> DinoState {
        var hasRunning = false
        for session in sessions {
            switch from(session) {
            case .action:            return .action  // short-circuit
            case .running:           hasRunning = true
            case .dormant, .expanded: continue
            }
        }
        return hasRunning ? .running : .dormant
    }
}
