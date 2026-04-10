import Foundation

@Observable
public final class AgentSession: Identifiable, @unchecked Sendable {
    public let id: String
    public let agentKind: AgentKind
    public let cwd: String
    public var pid: Int?  // Process ID for heartbeat checking
    public var missedHeartbeats: Int = 0  // Consecutive missed checks before marking dead
    public var projectName: String
    public var status: SessionStatus
    public var currentToolCall: ToolCall?
    public var pendingPermission: PermissionRequest?
    public var startTime: Date
    public var lastEventTime: Date
    public var subagentIds: [String]
    public var lastUserPrompt: String?

    public enum SessionStatus: Sendable {
        case active
        case waitingForInput
        case waitingForPermission
        case idle
        case stopped
    }

    public init(
        id: String,
        agentKind: AgentKind = .claudeCode,
        cwd: String,
        startTime: Date = .now
    ) {
        self.id = id
        self.agentKind = agentKind
        self.cwd = cwd
        self.projectName = (cwd as NSString).lastPathComponent
        self.status = .active
        self.currentToolCall = nil
        self.pendingPermission = nil
        self.startTime = startTime
        self.lastEventTime = startTime
        self.subagentIds = []
    }

    // MARK: - Reducer

    /// Apply an event to update session state. All state transitions in one place.
    public func apply(_ event: AgentEvent) {
        lastEventTime = .now

        switch event {
        case .sessionStarted:
            status = .active

        case .sessionEnded:
            status = .stopped

        case .toolStarted(let tool):
            currentToolCall = tool
            status = .active

        case .toolSucceeded:
            currentToolCall?.status = .succeeded
            currentToolCall?.endTime = .now
            status = .active

        case .toolFailed(let reason):
            currentToolCall?.status = .failed(reason)
            currentToolCall?.endTime = .now

        case .permissionRequested(let req):
            status = .waitingForPermission
            pendingPermission = req

        case .permissionResolved:
            pendingPermission = nil
            if status == .waitingForPermission {
                status = .active
            }

        case .notified:
            status = .waitingForInput

        case .stopped:
            status = .waitingForInput
            currentToolCall = nil

        case .subagentStarted(let childId):
            subagentIds.append(childId)

        case .subagentStopped:
            // A child agent finished — the parent session is still alive.
            // Earlier this set status = .stopped which then caused the
            // heartbeat sweep to delete the entire session, making the
            // notch panel falsely show "No active agents".
            if !subagentIds.isEmpty { subagentIds.removeLast() }
        }
    }

    /// Does this event mean a pending permission was resolved externally?
    public static func isResolutionEvent(_ event: AgentEvent) -> Bool {
        switch event {
        case .toolStarted, .toolSucceeded, .toolFailed, .stopped, .sessionEnded:
            return true
        default:
            return false
        }
    }
}
