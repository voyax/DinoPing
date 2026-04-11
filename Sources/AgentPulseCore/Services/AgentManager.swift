import Foundation
import os

@MainActor
@Observable
public final class AgentManager {
    public private(set) var sessions: [String: AgentSession] = [:]
    public var pendingPermissions: [PermissionRequest] = []
    public let permissionService = PermissionService()
    private let transcriptReader = TranscriptReader()

    public init() {
        startDiscovery()
    }

    private func startDiscovery() {
        Task {
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
            .filter { $0.status != .stopped }
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

        // Auto-cleanup stale permissions on resolution events
        if AgentSession.isResolutionEvent(agentEvent) {
            await MainActor.run {
                self.cleanupResolvedPermissions(sessionId: sessionId)
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

    private func cleanupResolvedPermissions(sessionId: String) {
        let staleIds = pendingPermissions.filter { $0.sessionId == sessionId }.map(\.id)
        guard !staleIds.isEmpty else { return }
        pendingPermissions.removeAll { $0.sessionId == sessionId }
        sessions[sessionId]?.apply(.permissionResolved)
        for id in staleIds {
            Task { await permissionService.resolve(requestId: id, decision: .deny(reason: "Resolved in terminal")) }
        }
    }

    @discardableResult
    public func getOrCreateSession(id: String, cwd: String) -> AgentSession {
        if let existing = sessions[id] { return existing }
        let session = AgentSession(id: id, cwd: cwd)
        sessions[id] = session
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
        let testIds = sessions.keys.filter { $0.hasPrefix("test-") || $0 == "debug-session" }
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
        for id in staleIds { sessions.removeValue(forKey: id) }
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
                // Skip if another session with the same cwd already exists
                // (e.g., hooks created a session with the real ID while
                // discovery only has a PID-based fallback ID)
                guard !existingCwds.contains(info.cwd) else { continue }

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
                if session.missedHeartbeats >= 2 {
                    session.status = .stopped
                    print("[AgentPulse] 💀 Process \(pid) gone — marking session \(session.projectName) as stopped")
                }
            }
        }
        // Remove stopped sessions
        let deadIds = sessions.filter { $0.value.status == .stopped }.map(\.key)
        for id in deadIds { sessions.removeValue(forKey: id) }
    }
}
