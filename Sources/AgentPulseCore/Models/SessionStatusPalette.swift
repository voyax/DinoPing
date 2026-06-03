import SwiftUI

/// Visual palette for `AgentSession.SessionStatus`.
///
/// | Status | Hex | When |
/// |---|---|---|
/// | working | `#0a84ff` | Tool actively executing |
/// | waiting | `#ff9f0a` | Pending permission or user question |
/// | idle    | white .55 | Turn finished, awaiting next user prompt |
/// | done    | `#30d158` | Session completed cleanly (terminal exited) |
/// | error   | `#ff453a` | Session failed / crashed |
///
/// `.idle` is an addition to the design spec's 4-state palette. The spec
/// didn't distinguish "agent finished its turn but session is alive" from
/// "session genuinely ended"; in practice the user needs to know which.
public enum StatusBadge: Sendable, Hashable {
    case working
    case waiting
    case idle
    case done
    case error

    /// Resolve a session's status (+ pending flags) to its badge identity.
    /// Pending permission OR question forces `.waiting` regardless of the
    /// raw status — those states block the user and need to read urgent.
    public static func from(_ session: AgentSession) -> StatusBadge {
        if session.pendingPermission != nil { return .waiting }
        if session.pendingQuestion != nil   { return .waiting }
        switch session.status {
        case .waitingForPermission: return .waiting
        case .active:               return .working
        // Agent finished its current turn and is waiting for the user's
        // next prompt — alive but quiet. NOT "Done" — that would imply
        // the session is over.
        case .waitingForInput:      return .idle
        case .idle:                 return .idle
        case .done:                 return .done
        case .stopped:              return .error
        }
    }

    public var label: String {
        switch self {
        case .working: "Working"
        case .waiting: "Needs you"
        case .idle:    "Idle"
        case .done:    "Done"
        case .error:   "Error"
        }
    }

    public var color: Color {
        switch self {
        case .working: Color(red: 0.039, green: 0.518, blue: 1.000)  // #0a84ff
        case .waiting: Color(red: 1.000, green: 0.624, blue: 0.039)  // #ff9f0a
        // Idle uses a neutral tone — green would over-promise "done",
        // a brighter gray-ish white reads as "quiet, not in your way"
        // while staying legible on the dark card / pill backgrounds.
        case .idle:    Color.white.opacity(0.75)
        case .done:    Color(red: 0.188, green: 0.820, blue: 0.345)  // #30d158
        case .error:   Color(red: 1.000, green: 0.271, blue: 0.227)  // #ff453a
        }
    }

    /// Same color (separate field so the design can drift the dot tint
    /// from the label tint later without renaming).
    public var dotColor: Color { color }

    /// Whether the status dot should pulse — only `.working`.
    public var shouldPulse: Bool {
        self == .working
    }
}
