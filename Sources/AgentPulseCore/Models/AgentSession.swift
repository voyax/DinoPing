import Foundation

/// `@unchecked Sendable` because @Observable classes can't be actors.
/// All mutable access MUST happen on @MainActor (enforced by AgentManager's
/// MainActor isolation). If you add a new callsite, ensure it runs on main.
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
    /// First ~120 chars of the most recent assistant response.
    public var lastAssistantMessage: String?
    /// Recent tool call history (last 5). Newest first.
    public var recentTools: [ToolCall] = []
    private static let maxRecentTools = 5
    /// Derived from the transcript file's mtime.
    public var lastActiveTime: Date?

    public enum SessionStatus: Sendable {
        case active
        case waitingForInput
        case waitingForPermission
        case idle
        case done      // session ended — shown briefly before removal
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
            status = .done

        case .toolStarted(let tool):
            currentToolCall = tool
            status = .active

        case .toolSucceeded:
            currentToolCall?.status = .succeeded
            currentToolCall?.endTime = .now
            // Archive to recent history
            if let completed = currentToolCall {
                recentTools.insert(completed, at: 0)
                if recentTools.count > Self.maxRecentTools {
                    recentTools.removeLast()
                }
            }
            status = .active

        case .toolFailed(let reason):
            currentToolCall?.status = .failed(reason)
            currentToolCall?.endTime = .now
            if let completed = currentToolCall {
                recentTools.insert(completed, at: 0)
                if recentTools.count > Self.maxRecentTools {
                    recentTools.removeLast()
                }
            }

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
            if !subagentIds.isEmpty { subagentIds.removeLast() }

        case .userPromptSubmitted:
            // The user just sent a message — Claude is about to think/respond.
            // Mark active so the pill shows "Working..." instead of "Waiting".
            status = .active
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
