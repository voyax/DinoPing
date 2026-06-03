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
    /// Set when Claude calls `AskUserQuestion`. Cleared when the matching
    /// `PostToolUse` arrives (matched by `pendingQuestionToolUseId`), the
    /// session resets, or a new user prompt arrives.
    public var pendingQuestion: AskUserQuestion?
    /// `tool_use_id` of the live `AskUserQuestion` call. Used to clear the
    /// banner when the *correct* tool completes — matching by `currentToolCall`
    /// is unreliable because parallel tools overwrite it before answer arrives.
    public var pendingQuestionToolUseId: String?
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
    /// Git branch resolved for `cwd` (via `GitBranch.refresh`). nil until
    /// the resolver has had a chance to run, or when the cwd isn't a git
    /// repo / is in detached HEAD state. Populated by `AgentManager` once
    /// per session, lazily refreshed by `SessionMetadataService`.
    public var branch: String?
    /// Token + cost aggregate, read from the session's transcript JSONL.
    /// Refreshed periodically by `SessionMetadataService` while the panel
    /// is expanded; nil before the first scan.
    public var usage: SessionUsage?
    /// Terminal / editor application that launched the agent, resolved
    /// once at session creation by walking the parent-process chain.
    /// `nil` when detection failed (unknown app, dead PID, missing pid).
    public var host: HostKind?

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
            // A dead session must not keep showing a question banner —
            // the terminal hosting the answer is gone.
            pendingQuestion = nil
            pendingQuestionToolUseId = nil

        case .toolStarted(let tool):
            currentToolCall = tool
            status = .active

        case .toolSucceeded(let toolUseId):
            // Match by toolUseId — `currentToolCall` may already point at a
            // sibling tool that fired after AskUserQuestion but completed
            // first, so name-matching it is unreliable.
            if let toolUseId, pendingQuestionToolUseId == toolUseId {
                pendingQuestion = nil
                pendingQuestionToolUseId = nil
            }
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

        case .toolFailed(let reason, let toolUseId):
            if let toolUseId, pendingQuestionToolUseId == toolUseId {
                pendingQuestion = nil
                pendingQuestionToolUseId = nil
            }
            currentToolCall?.status = .failed(reason)
            currentToolCall?.endTime = .now
            if let completed = currentToolCall {
                recentTools.insert(completed, at: 0)
                if recentTools.count > Self.maxRecentTools {
                    recentTools.removeLast()
                }
            }
            status = .active

        case .permissionRequested(let req):
            status = .waitingForPermission
            pendingPermission = req

        case .permissionResolved:
            pendingPermission = nil
            status = .active

        case .notified:
            status = .waitingForInput

        case .stopped:
            status = .waitingForInput
            currentToolCall = nil
            pendingQuestion = nil
            pendingQuestionToolUseId = nil

        case .subagentStarted(let childId):
            subagentIds.append(childId)

        case .subagentStopped:
            // A child agent finished — the parent session is still alive.
            if !subagentIds.isEmpty { subagentIds.removeLast() }

        case .userPromptSubmitted:
            // New turn — clear all stale state from the previous exchange.
            status = .active
            recentTools = []
            currentToolCall = nil
            lastAssistantMessage = nil
            pendingQuestion = nil
            pendingQuestionToolUseId = nil

        case .questionAsked(let question, let toolUseId):
            pendingQuestion = question
            pendingQuestionToolUseId = toolUseId
            status = .waitingForInput
        }
    }

    /// Does this event mean a pending permission was resolved externally?
    ///
    /// `.toolStarted` is deliberately excluded: `PreToolUse` fires *before*
    /// Claude Code checks permission, so the fact that a tool is starting
    /// says nothing about whether the user approved — treating it as a
    /// resolution was a bug that wiped still-waiting permission cards.
    public static func isResolutionEvent(_ event: AgentEvent) -> Bool {
        switch event {
        case .toolSucceeded, .toolFailed, .stopped, .sessionEnded:
            return true
        case .sessionStarted, .toolStarted, .permissionRequested,
             .permissionResolved, .notified, .subagentStarted,
             .subagentStopped, .userPromptSubmitted, .questionAsked:
            return false
        }
    }
}
