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
            for (info, prompt) in discovered {
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

            // Fix #1: Only add to pendingPermissions here (HTTP hook path).
            // The bridge /api/approve path does NOT go through handleEvent,
            // so there is no duplication.
            if case .permissionRequested(let req) = agentEvent {
                // Deduplicate: don't add if already present
                if !self.pendingPermissions.contains(where: { $0.id == req.id }) {
                    self.pendingPermissions.append(req)
                }
            }
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

    /// Removes every session — used by `/debug/sessions/clear` for visual
    /// testing of the empty state. Not meant for production paths.
    public func debugRemoveAllSessions() {
        sessions.removeAll()
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
            for (info, prompt) in discovered {
                if sessions[info.sessionId] == nil {
                    let session = AgentSession(id: info.sessionId, agentKind: info.agentKind, cwd: info.cwd)
                    session.status = .waitingForInput
                    session.pid = info.pid
                    session.lastUserPrompt = prompt
                    sessions[info.sessionId] = session
                }
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
