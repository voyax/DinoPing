import Foundation
import os

@MainActor
@Observable
public final class AgentManager {
    public private(set) var sessions: [String: AgentSession] = [:]
    public var pendingPermissions: [PermissionRequest] = []
    public let permissionService = PermissionService()
    private let transcriptReader = TranscriptReader()
    private var discoveryTask: Task<Void, Never>?
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
                session.status = .waitingForInput
                session.pid = info.pid
                session.lastUserPrompt = prompt
                self.sessions[info.sessionId] = session
            }
            if !discovered.isEmpty {
                print("[AgentPulse] 🔍 Discovered \(discovered.count) existing session(s)")
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

        // Apply reducer
        await MainActor.run {
            let session = self.getOrCreateSession(id: sessionId, cwd: payload.cwd)
            session.apply(agentEvent)
            if let latestPrompt { session.lastUserPrompt = latestPrompt }

            if case .permissionRequested(let req) = agentEvent {
                if !self.pendingPermissions.contains(where: { $0.id == req.id }) {
                    self.pendingPermissions.append(req)
                }
            }
        }

        // Re-read transcript shortly after the hook — hooks often fire
        // *before* the message is fully written to the jsonl file. A short
        // delay lets the write complete so we pick up the latest content.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            await self?.refreshAllPrompts()
        }

        return .empty
    }

    // MARK: - User Actions (Fix #12: separate bypass from allow)

    public func approvePermission(id: String) {
        pendingPermissions.removeAll { $0.id == id }
        for s in sessions.values where s.pendingPermission?.id == id { s.apply(.permissionResolved) }
        Task { await permissionService.resolve(requestId: id, decision: .allow) }
    }

    public func bypassPermission(id: String) {
        pendingPermissions.removeAll { $0.id == id }
        for s in sessions.values where s.pendingPermission?.id == id { s.apply(.permissionResolved) }
        Task { await permissionService.resolve(requestId: id, decision: .bypass) }
    }

    public func denyPermission(id: String, reason: String = "Denied by user") {
        pendingPermissions.removeAll { $0.id == id }
        for s in sessions.values where s.pendingPermission?.id == id { s.apply(.permissionResolved) }
        Task { await permissionService.resolve(requestId: id, decision: .deny(reason: reason)) }
    }

    // MARK: - Private

    /// Clean up pending permissions that have been resolved outside the notch
    /// (e.g. user approved in the terminal, or the tool finished, or the
    /// session ended). When `toolUseId` is non-nil we only match the specific
    /// request whose `toolUseId` matches — so concurrent tools in the same
    /// session don't wipe each other. Match is on `request.toolUseId`, not
    /// `request.id`, since `id` is a fresh UUID per request now.
    private func cleanupResolvedPermissions(sessionId: String, toolUseId: String?) {
        let staleIds: [String]
        if let toolUseId, !toolUseId.isEmpty {
            staleIds = pendingPermissions
                .filter { $0.sessionId == sessionId && $0.toolUseId == toolUseId }
                .map(\.id)
        } else {
            // No toolUseId (Stop / SessionEnd) → clear everything for the session.
            staleIds = pendingPermissions.filter { $0.sessionId == sessionId }.map(\.id)
        }
        guard !staleIds.isEmpty else { return }
        pendingPermissions.removeAll { staleIds.contains($0.id) }
        for session in sessions.values where staleIds.contains(session.pendingPermission?.id ?? "") {
            session.apply(.permissionResolved)
        }
        for id in staleIds {
            Task { await permissionService.resolve(requestId: id, decision: .deny(reason: "Resolved in terminal")) }
        }
    }

    @discardableResult
    public func getOrCreateSession(id: String, cwd: String) -> AgentSession {
        if let existing = sessions[id] { return existing }
        let session = AgentSession(id: id, cwd: cwd)
        sessions[id] = session
        // Register the new session's transcript for file watching
        if let url = transcriptReader.transcriptURL(cwd: cwd, sessionId: id) {
            transcriptWatcher?.watch(path: url.path)
        }
        return session
    }

    /// Removes every session — used by `/debug/sessions/clear`.
    public func debugRemoveAllSessions() {
        sessions.removeAll()
    }

    /// Removes sessions created by test/debug endpoints (IDs starting with
    /// "test-" or "debug-session"). Prevents test artifacts from cluttering
    /// the real session list.
    public func cleanupTestSessions() {
        // Real IDs: hex UUIDs ("64c6ce89-...") or PID-based ("proc-1234").
        // Anything else is a test/debug artifact.
        let hexChars = CharacterSet(charactersIn: "0123456789abcdef")
        let testIds = sessions.keys.filter { id in
            if id.hasPrefix("proc-") { return false }
            let prefix = String(id.prefix(8))
            return prefix.unicodeScalars.contains(where: { !hexChars.contains($0) })
        }
        for id in testIds { sessions.removeValue(forKey: id) }
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
            sessions.removeValue(forKey: id)
        }
    }

    /// Resolve any pending permissions belonging to a session that's about
    /// to be removed. Without this, an orphan card can outlive its session
    /// in the UI and the bridge continuation leaks until 24h backstop fires.
    ///
    /// Mirrors the (manager array + per-session field + actor resume) trio
    /// of `approvePermission`/`denyPermission` so the helper is safe to
    /// reuse from any caller — not just the cleanup paths that happen to
    /// remove the session in the same cycle.
    private func denyPendingPermissions(forSessionId sessionId: String, reason: String) {
        let orphanIds = pendingPermissions.filter { $0.sessionId == sessionId }.map(\.id)
        guard !orphanIds.isEmpty else { return }
        pendingPermissions.removeAll { $0.sessionId == sessionId }
        for s in sessions.values where orphanIds.contains(s.pendingPermission?.id ?? "") {
            s.apply(.permissionResolved)
        }
        for id in orphanIds {
            Task { await permissionService.resolve(requestId: id, decision: .deny(reason: reason)) }
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
                // Skip if this session ID already exists
                guard sessions[info.sessionId] == nil else { continue }
                // Skip PID-based fallback IDs if another session with the
                // same cwd exists (hooks provide the real ID). But allow
                // transcript-matched IDs even for the same cwd — those are
                // genuinely different sessions in the same directory.
                if info.sessionId.hasPrefix("proc-"),
                   existingCwds.contains(info.cwd) { continue }

                let session = AgentSession(id: info.sessionId, agentKind: info.agentKind, cwd: info.cwd)
                session.status = .waitingForInput
                session.pid = info.pid
                session.lastUserPrompt = prompt
                sessions[info.sessionId] = session
            }
        }
    }

    /// Check if discovered processes are still alive (kill -0 pid).
    /// Requires 2 consecutive misses before marking as stopped (debounce).
    public func heartbeatCheck() {
        for session in sessions.values {
            guard let pid = session.pid, pid > 0 else { continue }
            let alive = kill(Int32(pid), 0) == 0
            if alive {
                session.missedHeartbeats = 0
            } else {
                session.missedHeartbeats += 1
                if session.missedHeartbeats >= 2, session.status != .done {
                    session.status = .done
                    session.lastEventTime = .now  // start the 8s grace timer
                    print("[AgentPulse] 💀 Process \(pid) gone — \(session.projectName) done")
                }
            }
        }

        // Remove sessions that have been .done for 8+ seconds, or .stopped.
        let now = Date.now
        let removeIds = sessions.filter { _, s in
            if s.status == .stopped { return true }
            if s.status == .done {
                return now.timeIntervalSince(s.lastEventTime) > 8
            }
            return false
        }.map(\.key)
        for id in removeIds {
            denyPendingPermissions(forSessionId: id, reason: "Session ended")
            sessions.removeValue(forKey: id)
        }
    }
}
