import Foundation
import os

/// Centralized poller that keeps `AgentSession.branch` and `.usage` up to
/// date for every active session. Replaces per-card `.task` blocks — the
/// view layer becomes pure presentation that reads `session.branch` and
/// `session.usage` directly.
///
/// Lifecycle (owned by the host app, typically `NotchPanel`):
/// - `start(agentManager:)` when the panel transitions to `.expanded`
/// - `stop()` when the panel collapses back to `.compact` or `.dormant`
///
/// Branch resolution is fire-and-forget per session — cwd doesn't change
/// during a session, so one lookup is usually enough (the 30s cache in
/// `GitBranch` handles incidental retries). Usage aggregation is a
/// 10-second poll because transcripts grow as agents work and the user
/// wants to watch token/cost climb in near-real-time.
@MainActor
public final class SessionMetadataService {
    /// Interval between transcript re-scans for usage data. 10s balances
    /// freshness (the user sees the token/cost number climb without 60s+
    /// staleness) against disk I/O (each scan reads the transcript file).
    public static let pollInterval: Duration = .seconds(10)

    private weak var agentManager: AgentManager?
    private var pollTask: Task<Void, Never>?
    private let aggregator = SessionUsageAggregator()

    public init() {}

    public func start(agentManager: AgentManager) {
        guard pollTask == nil else { return }   // idempotent
        self.agentManager = agentManager
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Fire a one-shot branch lookup for a newly-discovered session.
    /// Branch doesn't change mid-session in any sane workflow (people
    /// don't usually `git checkout` while Claude is running), so once is
    /// enough until the 30s `GitBranch` cache expires naturally.
    ///
    /// `Task { @MainActor ... }` is explicit so the write to
    /// `session.branch` lands on MainActor even after the `await
    /// GitBranch.refresh` suspension. Without the annotation, capturing
    /// `[weak session]` makes the closure `@Sendable` and Swift 6 selects
    /// the non-isolation-inheriting `Task.init` overload, which would
    /// race AgentManager / reducer writes on the same session.
    public func resolveBranch(for session: AgentSession) {
        let cwd = session.cwd
        Task { @MainActor [weak session] in
            // Hit the cache first to avoid spawning a subprocess when
            // another session in the same cwd already resolved it.
            if let cached = GitBranch.cached(for: cwd) {
                session?.branch = cached
                return
            }
            session?.branch = await GitBranch.refresh(cwd: cwd)
        }
    }

    /// Fire a one-shot host detection by walking the parent-process
    /// chain. PID doesn't change for a live session, so once is enough.
    /// Runs on a background queue (libproc syscalls don't need MainActor).
    public func resolveHost(for session: AgentSession) {
        guard let pid = session.pid else { return }
        Task { @MainActor [weak session] in
            let host = await Task.detached(priority: .background) {
                HostDetector.detect(for: pid_t(pid))
            }.value
            session?.host = host
        }
    }

    // MARK: - Internal

    private func pollLoop() async {
        while !Task.isCancelled {
            await scanAllSessions()
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    /// Scan every active session's transcript, updating `session.usage`
    /// in place. Aggregation runs on a background queue so the 5–50 MB
    /// file reads never block MainActor.
    private func scanAllSessions() async {
        guard let manager = agentManager else { return }
        let sessions = manager.activeSessions
        guard !sessions.isEmpty else { return }

        // Snapshot the (id, cwd) tuples so we can pass plain values into
        // the detached task. AgentSession is class-typed but we're
        // writing back via the captured weak reference per session.
        let targets: [(weak: WeakBox<AgentSession>, cwd: String, sid: String)] = sessions.map {
            (WeakBox($0), $0.cwd, $0.id)
        }

        for target in targets {
            let aggregator = self.aggregator
            let cwd = target.cwd
            let sid = target.sid
            let result = await Task.detached(priority: .background) {
                aggregator.aggregate(cwd: cwd, sessionId: sid)
            }.value
            // Hop back to MainActor (we're already there — the task
            // inherits from this method). Just write the result.
            target.weak.value?.usage = result
        }
    }
}

// MARK: - Helpers

/// Plain weak-reference wrapper so we can hold weak handles inside a
/// regular collection (Swift collections don't have first-class weak
/// element support).
private final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

// MARK: - Logging

private extension Logger {
    static let metadataService = Logger(subsystem: "com.agentpulse", category: "SessionMetadata")
}
