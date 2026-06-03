import Foundation
import os

@MainActor
@Observable
public final class AgentManager {
    public private(set) var sessions: [String: AgentSession] = [:]
    public var pendingPermissions: [PermissionRequest] = []
    /// Per-permission bypass-confirm: the request ID that's currently armed
    /// for bypass. Both keyboard (NotchPanel) and UI (PermissionBanner)
    /// read/write this so the visual "Confirm?" is scoped to one banner.
    public var bypassArmedId: String?
    /// Bulk confirm states — on AgentManager so NotchPanel can pause hover
    /// collapse while the user is mid-confirm on Allow All / Deny All.
    public var allowAllConfirm: Bool = false
    public var denyAllConfirm: Bool = false
    public let permissionService = PermissionService()
    private let transcriptReader = TranscriptReader()
    private var discoveryTask: Task<Void, Never>?
    private var refreshDebounceTask: Task<Void, Never>?
    public private(set) var transcriptWatcher: TranscriptWatcher?

    public init() {
        startDiscovery()
    }

    private func startDiscovery() {
        discoveryTask = Task {
            let reader = self.transcriptReader
            let discovered = await Task.detached {
                let sessions = SessionDiscovery().discoverClaudeCodeSessions()
                // Pre-load latest user prompts off the main actor
                return sessions.map { info -> (SessionDiscovery.DiscoveredSession, String?) in
                    (info, reader.latestUserPrompt(cwd: info.cwd, sessionId: info.sessionId))
                }
            }.value
            var seenCwds = Set<String>()
            for (info, prompt) in discovered {
                guard !seenCwds.contains(info.cwd) else { continue }
                seenCwds.insert(info.cwd)
                let session = AgentSession(id: info.sessionId, agentKind: info.agentKind, cwd: info.cwd)
                // Direct set: initialization of discovered session, not a state
                // transition — session hasn't entered the event flow yet.
                session.status = .waitingForInput
                session.pid = info.pid
                session.lastUserPrompt = prompt
                self.sessions[info.sessionId] = session
            }
            if !discovered.isEmpty {
                Logger.agentManager.info("Discovered \(discovered.count, privacy: .public) existing sessions")
            }
        }
    }

    public var activeSessions: [AgentSession] {
        sessions.values
            .filter { $0.status != .stopped }  // .done is still shown
            .sorted { $0.lastEventTime > $1.lastEventTime }
    }

    public var hasPendingPermissions: Bool {
        !pendingPermissions.isEmpty
    }

    // MARK: - Event Handling

    nonisolated public func handleEvent(_ event: HookEvent) async -> HookResponse {
        let agentEvent = AgentEvent.from(event)
        let payload = event.payload
        let sessionId = payload.sessionId

        // Auto-cleanup stale permissions on resolution events.
        // Match by toolUseId when available so parallel tools in the same
        // session don't wipe each other's pending permissions. `Stop` and
        // `SessionEnd` carry no toolUseId — those clean the whole session.
        if AgentSession.isResolutionEvent(agentEvent) {
            let toolUseId = payload.toolUseId
            await MainActor.run {
                self.cleanupResolvedPermissions(sessionId: sessionId, toolUseId: toolUseId)
            }
        }

        // Refresh latest user prompt off the main actor (transcript file I/O)
        let reader = self.transcriptReader
        let cwd = payload.cwd
        let latestPrompt = await Task.detached {
            reader.latestUserPrompt(cwd: cwd, sessionId: sessionId)
        }.value

        // Apply reducer. Permission registration happens exclusively in
        // the bridge approval handler (AppState), not here — the HTTP hook
        // route for PermissionRequest was deleted.
        await MainActor.run {
            let session = self.getOrCreateSession(id: sessionId, cwd: payload.cwd)
            session.apply(agentEvent)
            if let latestPrompt { session.lastUserPrompt = latestPrompt }

            // Post-reducer reconciliation for stale permissions and questions.
            //
            // CRITICAL: only check after events that prove external resolution
            // (tool executing, session ended). NOT on .notified, .subagent*,
            // .questionAsked — those can arrive while legitimately pending.
            if Self.isExternalResolutionSignal(agentEvent) {
                // Stale permission: tool started = permission granted in terminal
                if session.pendingPermission != nil {
                    let orphanIds = self.pendingPermissions
                        .filter { $0.sessionId == sessionId }
                        .map(\.id)
                    self.resolvePermissions(
                        ids: orphanIds,
                        decision: .deny(reason: "Resolved externally")
                    )
                    session.apply(.permissionResolved)
                }

                // Stale question: a DIFFERENT tool started = user answered,
                // Claude moved on. Skip if this is AskUserQuestion's own
                // tool event (same toolUseId) — the reducer handles that.
                if session.pendingQuestion != nil {
                    let eventToolUseId: String? = switch agentEvent {
                    case .toolStarted(let t): t.id
                    case .toolSucceeded(let id), .toolFailed(_, let id): id
                    default: nil
                    }
                    if eventToolUseId != session.pendingQuestionToolUseId {
                        session.pendingQuestion = nil
                        session.pendingQuestionToolUseId = nil
                    }
                }
            }
        }

        // Re-read transcript shortly after the hook — hooks often fire
        // *before* the message is fully written to the jsonl file. Debounced:
        // only the last event in a burst triggers the refresh (60 rapid hooks
        // no longer spawn 60 independent transcript reads).
        await MainActor.run { self.schedulePromptRefresh() }

        return .empty
    }

    // MARK: - Permission Resolution
    //
    // Every permission resolution must do the "triple write":
    //   1. Remove from pendingPermissions array (drives pill count)
    //   2. Clear session.pendingPermission (drives inline banner)
    //   3. Resume the PermissionService continuation (unblocks bridge)
    // All 3 must stay in sync; resolvePermission is the single entry point.

    public func approvePermission(id: String) {
        resolvePermission(id: id, decision: .allow)
    }

    public func bypassPermission(id: String) {
        resolvePermission(id: id, decision: .bypass)
    }

    public func denyPermission(id: String, reason: String = "Denied by user") {
        resolvePermission(id: id, decision: .deny(reason: reason))
    }

    /// Single coordinator for the triple write. Safe to call multiple times
    /// for the same id — each step is individually idempotent.
    public func resolvePermission(id: String, decision: PermissionDecision) {
        pendingPermissions.removeAll { $0.id == id }
        for s in sessions.values where s.pendingPermission?.id == id {
            s.apply(.permissionResolved)
        }
        Task { await permissionService.resolve(requestId: id, decision: decision) }
    }

    /// Batch-resolve multiple permissions with the same decision.
    private func resolvePermissions(ids: [String], decision: PermissionDecision) {
        guard !ids.isEmpty else { return }
        pendingPermissions.removeAll { ids.contains($0.id) }
        for session in sessions.values where ids.contains(session.pendingPermission?.id ?? "") {
            session.apply(.permissionResolved)
        }
        for id in ids {
            Task { await permissionService.resolve(requestId: id, decision: decision) }
        }
    }

    // MARK: - Private

    /// Clean up pending permissions resolved outside the notch (terminal
    /// approval, tool completion, session end). Scoped by toolUseId when
    /// available so parallel tools don't wipe each other's cards.
    private func cleanupResolvedPermissions(sessionId: String, toolUseId: String?) {
        let staleIds: [String]
        if let toolUseId, !toolUseId.isEmpty {
            staleIds = pendingPermissions
                .filter { $0.sessionId == sessionId && $0.toolUseId == toolUseId }
                .map(\.id)
        } else {
            staleIds = pendingPermissions.filter { $0.sessionId == sessionId }.map(\.id)
        }
        resolvePermissions(ids: staleIds, decision: .deny(reason: "Resolved in terminal"))
    }

    @discardableResult
    public func getOrCreateSession(id: String, cwd: String) -> AgentSession {
        if let existing = sessions[id] { return existing }
        let session = AgentSession(id: id, cwd: cwd)
        sessions[id] = session
        // Hook payloads carry no pid — resolve one in the background so the
        // fast liveness loop can detect this session's exit. Without this,
        // hook-created sessions stay pid-less and only the 30-min stale
        // timeout would ever remove them.
        backfillPid(for: session)
        // Register the new session's transcript for file watching
        if let url = transcriptReader.transcriptURL(cwd: cwd, sessionId: id) {
            transcriptWatcher?.watch(path: url.path)
        }
        return session
    }

    /// Events that prove a permission was resolved externally (terminal
    /// approval, session end). Used by the post-reducer cleanup to avoid
    /// false positives from events like `.notified` that change status
    /// without implying permission was granted.
    private static func isExternalResolutionSignal(_ event: AgentEvent) -> Bool {
        switch event {
        case .toolStarted, .toolSucceeded, .toolFailed,
             .sessionEnded, .stopped, .userPromptSubmitted:
            return true
        case .sessionStarted, .permissionRequested, .permissionResolved,
             .notified, .subagentStarted, .subagentStopped, .questionAsked:
            return false
        }
    }

    /// Remove a session and unwatch its transcript file.
    private func removeSession(_ id: String) {
        guard let session = sessions[id] else { return }
        if let url = transcriptReader.transcriptURL(cwd: session.cwd, sessionId: session.id) {
            transcriptWatcher?.unwatch(path: url.path)
        }
        sessions.removeValue(forKey: id)
    }

    /// Removes every session — used by `/debug/sessions/clear`.
    public func debugRemoveAllSessions() {
        for id in Array(sessions.keys) {
            denyPendingPermissions(forSessionId: id, reason: "Debug clear")
            removeSession(id)
        }
    }

    /// Removes sessions created by test/debug endpoints. Matches the known
    /// prefixes used by `/debug/test/*` and `/test/approve` routes.
    public func cleanupTestSessions() {
        let testPrefixes = ["test-", "debug-", "fake-"]
        let testIds = sessions.keys.filter { id in
            testPrefixes.contains(where: { id.hasPrefix($0) })
        }
        for id in testIds { removeSession(id) }
    }

    /// Remove pendingPermissions entries whose session no longer has a
    /// matching `pendingPermission`. These orphans arise when a resolution
    /// path clears the per-session field but misses the array (e.g., terminal
    /// approval via PostToolUse with a mismatched toolUseId, or a race between
    /// the bridge and an event handler). Called every 30s from the cleanup loop.
    public func reconcilePendingPermissions() {
        let now = Date.now
        let staleIds = pendingPermissions.filter { req in
            // Only reconcile entries older than 10s — a fresh permission might
            // still be in flight between the approval handler's MainActor.run
            // blocks. 10s is generous; the post-reducer cleanup in handleEvent
            // is the primary fix, this is the safety net.
            guard now.timeIntervalSince(req.receivedAt) > 10 else { return false }
            guard let session = sessions[req.sessionId] else { return true }
            return session.pendingPermission?.id != req.id
        }.map(\.id)
        resolvePermissions(ids: staleIds, decision: .deny(reason: "Stale (reconciled)"))
    }

    public func cleanupStaleSessions() {
        let cutoff = Date.now.addingTimeInterval(-Constants.sessionTimeoutSeconds)
        let staleIds = sessions.filter { _, session in
            // Only remove if BOTH conditions are true:
            // 1. No events for a long time AND idle/waiting
            // 2. Process is actually dead (or has no PID to check)
            guard session.lastEventTime < cutoff,
                  session.status == .idle || session.status == .waitingForInput else {
                return false
            }
            if let pid = session.pid, pid > 0 {
                let alive = kill(Int32(pid), 0) == 0
                if alive { return false }  // process still running — keep it
            }
            return true
        }.map(\.key)
        for id in staleIds {
            denyPendingPermissions(forSessionId: id, reason: "Session ended")
            removeSession(id)
        }
    }

    /// Deny all pending permissions for a session about to be removed.
    private func denyPendingPermissions(forSessionId sessionId: String, reason: String) {
        let orphanIds = pendingPermissions.filter { $0.sessionId == sessionId }.map(\.id)
        resolvePermissions(ids: orphanIds, decision: .deny(reason: reason))
    }

    private func schedulePromptRefresh() {
        refreshDebounceTask?.cancel()
        refreshDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.refreshAllPrompts()
        }
    }

    /// Install a file watcher that triggers refreshAllPrompts on transcript
    /// file writes. Call once at startup; sessions auto-register their files.
    public func installTranscriptWatcher() {
        let mgr = self
        transcriptWatcher = TranscriptWatcher { [weak mgr] in
            Task { await mgr?.refreshAllPrompts() }
        }
        // Watch all current sessions' transcripts
        updateWatchedPaths()
    }

    /// Ensure the watcher covers all active session transcripts.
    public func updateWatchedPaths() {
        guard let watcher = transcriptWatcher else { return }
        for session in sessions.values {
            if let url = transcriptReader.transcriptURL(cwd: session.cwd, sessionId: session.id) {
                watcher.watch(path: url.path)
            }
        }
    }

    /// Re-read the latest user prompt + transcript mtime from each session.
    /// Called on a 5-second timer so the notch panel stays current even
    /// during pure-text conversations where no tool-use hooks fire.
    nonisolated public func refreshAllPrompts() async {
        let reader = self.transcriptReader
        let snapshot = await MainActor.run { Array(self.sessions.values.map { ($0.id, $0.cwd) }) }
        let results = await Task.detached {
            snapshot.map { (id, cwd) -> (String, String?, String?, Date?) in
                let prompt = reader.latestUserPrompt(cwd: cwd, sessionId: id)
                let reply = reader.latestAssistantMessage(cwd: cwd, sessionId: id)
                let mtime = reader.transcriptModificationDate(cwd: cwd, sessionId: id)
                return (id, prompt, reply, mtime)
            }
        }.value
        await MainActor.run {
            for (id, prompt, reply, mtime) in results {
                guard let session = self.sessions[id] else { continue }
                if let prompt, session.lastUserPrompt != prompt {
                    session.lastUserPrompt = prompt
                }
                if let reply, session.lastAssistantMessage != reply {
                    session.lastAssistantMessage = reply
                }
                if let mtime { session.lastActiveTime = mtime }
            }
        }
    }

    /// Re-run process discovery to find sessions we may have missed or
    /// cleaned up while the process was still alive. Safe to call anytime.
    public func rediscover() {
        Task {
            let reader = self.transcriptReader
            let discovered = await Task.detached {
                let sessions = SessionDiscovery().discoverClaudeCodeSessions()
                return sessions.map { info -> (SessionDiscovery.DiscoveredSession, String?) in
                    (info, reader.latestUserPrompt(cwd: info.cwd, sessionId: info.sessionId))
                }
            }.value
            let existingCwds = Set(sessions.values.map(\.cwd))
            for (info, prompt) in discovered {
                // Already tracked? Backfill a pid if it's still missing
                // (hook-created sessions arrive without one), then move on.
                // This is the catch-all behind the creation-time backfill.
                if let existing = sessions[info.sessionId] {
                    if existing.pid == nil {
                        // The transcript is authoritative about which session
                        // owns this pid. If another session is wrongly holding
                        // it (a backfill that raced a same-cwd restart, or a
                        // recycled pid), reclaim it — self-heals a mis-binding
                        // within one slow-sweep instead of letting the bad
                        // session linger up to 30 minutes.
                        if let usurper = sessions.values.first(
                            where: { $0.id != existing.id && $0.pid == info.pid }
                        ) {
                            usurper.pid = nil
                        }
                        existing.pid = info.pid
                    }
                    continue
                }
                // Skip PID-based fallback IDs if another session with the
                // same cwd exists (hooks provide the real ID). But allow
                // transcript-matched IDs even for the same cwd — those are
                // genuinely different sessions in the same directory.
                if info.sessionId.hasPrefix("proc-"),
                   existingCwds.contains(info.cwd) { continue }

                let session = AgentSession(id: info.sessionId, agentKind: info.agentKind, cwd: info.cwd)
                session.status = .waitingForInput  // initialization, not transition
                session.pid = info.pid
                session.lastUserPrompt = prompt
                sessions[info.sessionId] = session
            }
        }
    }

    /// Fast death detection from a single `ps` snapshot (passed in from an
    /// off-main poll). A pid-bearing session whose pid is absent from the
    /// live set has exited — mark it ended immediately. No debounce: `ps`
    /// is authoritative, unlike the old per-session `kill(pid,0)` which
    /// needed 2 misses to absorb transient errors.
    ///
    /// Sessions with `pid == nil` (backfill pending/failed, or extra team
    /// members sharing one pid) are NOT touched here — they fall back to
    /// `cleanupStaleSessions`. Backfill normally attaches a pid within
    /// seconds, so this covers the common case.
    public func reconcileLiveness(livePids: Set<Int>) {
        for session in sessions.values {
            guard let pid = session.pid, pid > 0 else { continue }
            if !livePids.contains(pid), session.status != .done {
                session.apply(.sessionEnded)
                Logger.agentManager.info("PID \(pid, privacy: .public) gone — \(session.projectName, privacy: .public) done")
            }
        }
        pruneFinishedSessions()
    }

    /// Remove sessions that have finished: `.stopped`, or `.done` for longer
    /// than the linger window. Also sweeps orphaned `proc-<pid>` placeholders.
    private func pruneFinishedSessions() {
        let now = Date.now
        let removeIds = sessions.filter { id, s in
            if s.status == .stopped { return true }
            if s.status == .done {
                return now.timeIntervalSince(s.lastEventTime) > Constants.doneLingerSeconds
            }
            // A `proc-<pid>` session's whole identity IS its pid — it's the
            // fallback we mint when a live process can't be matched to a
            // transcript. If self-heal later reclaims that pid for the real
            // (hook/transcript) session, the placeholder is left pid-less and
            // redundant. Liveness can't reap it (no pid to check), so it would
            // double-count the same process until the 30-min cleanup. Drop it.
            if id.hasPrefix("proc-"), s.pid == nil { return true }
            return false
        }.map(\.key)
        for id in removeIds {
            denyPendingPermissions(forSessionId: id, reason: "Session ended")
            removeSession(id)
        }
    }

    // MARK: - PID backfill

    /// True if `pid` is already bound to some session other than `excluding`.
    /// Used to keep pid→session assignment exclusive so two sessions never
    /// claim the same process.
    private func pidIsTaken(_ pid: Int, excluding sessionId: String) -> Bool {
        sessions.values.contains { $0.id != sessionId && $0.pid == pid }
    }

    /// Resolve and attach a pid to a hook-created session (which arrives
    /// without one — Claude Code hook payloads carry no pid). Retries briefly
    /// because the process may not be visible the instant the first hook fires.
    ///
    /// Matching goes through the transcript-authoritative discovery (the same
    /// mapping `rediscover` uses), NOT bare cwd. A bare-cwd match would let a
    /// stale pid-less session steal the live process of a *different* session
    /// that shares its directory (e.g. claude restarted in the same repo),
    /// inflating the count. `discoverClaudeCodeSessions` maps each live pid to
    /// the session whose transcript it owns, so we only ever bind the pid that
    /// genuinely belongs to `sid`.
    private func backfillPid(for session: AgentSession) {
        let sid = session.id
        Task { [weak self] in
            for _ in 0..<5 {
                guard let self else { return }
                guard self.sessions[sid]?.pid == nil else { return }
                let discovered = await Task.detached {
                    SessionDiscovery().discoverClaudeCodeSessions()
                }.value
                if self.bindDiscoveredPid(discovered, to: sid) { return }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Bind the pid whose discovered session id matches `sessionId`, provided
    /// no other session already holds it. Returns true when the backfill loop
    /// should stop — bound, session gone, or session already has a pid. Returns
    /// false (keep retrying) only when no live process maps to this session yet.
    private func bindDiscoveredPid(
        _ discovered: [SessionDiscovery.DiscoveredSession],
        to sessionId: String
    ) -> Bool {
        guard let session = sessions[sessionId] else { return true }
        guard session.pid == nil else { return true }
        guard let match = discovered.first(where: { $0.sessionId == sessionId }),
              !pidIsTaken(match.pid, excluding: sessionId) else {
            return false
        }
        session.pid = match.pid
        return true
    }
}
