import Foundation
import os

/// Manages pending permission approvals for the bridge-based flow.
///
/// Safety:
/// - resolve() atomically removes continuation (no double-resume)
/// - Early resolutions are buffered (resolve before awaitDecision)
/// - 24h backstop timer in case neither user click nor cancellation fires
/// - withTaskCancellationHandler catches bridge HTTP disconnect
public actor PermissionService {
    private var pending: [String: CheckedContinuation<PermissionDecision, Never>] = [:]
    /// Buffer for resolutions that arrive before awaitDecision stores the continuation.
    private var earlyResolutions: [String: PermissionDecision] = [:]
    /// IDs that have already been resolved — prevents double-resume from
    /// concurrent "Allow All" + individual card button clicks.
    private var resolved: Set<String> = []

    /// Matches the bridge URLSession + Claude Code hook timeout (24h).
    /// Defense-in-depth: even if Hummingbird's cancellation doesn't fire and
    /// the user never clicks, we eventually clean up so the actor's `pending`
    /// dict can't grow unboundedly.
    private static let backstopTimeoutSeconds: UInt64 = 86400

    /// Number of continuations currently waiting. Exposed for tests so they
    /// can poll until registration completes instead of using fragile sleeps.
    public var pendingCount: Int { pending.count }

    public init() {}

    /// Block until the user makes a decision in the notch UI.
    ///
    /// Three cleanup paths:
    /// 1. **User click** → `resolve()` from `AgentManager.approvePermission` etc.
    /// 2. **Bridge disconnect** → Hummingbird cancels the route Task (only when
    ///    the route is wrapped in `consumeWithCancellationOnInboundClose` —
    ///    see `HookHTTPServer.swift`). `withTaskCancellationHandler.onCancel`
    ///    schedules a deny so the UI clears.
    /// 3. **24h backstop** → defensive timer matching the bridge timeout. Should
    ///    never normally fire; if it does, the bridge is long dead anyway.
    ///
    /// Why a backstop on top of cancellation: Hummingbird only delivers Task
    /// cancellation on inbound close when the route opts in via the
    /// `consumeWithCancellationOnInboundClose` wrapper. The backstop is the
    /// belt to that suspenders, in case the route is ever refactored away
    /// from that wrapper or the wrapper has edge cases we haven't found.
    public func awaitDecision(for requestId: String) async -> PermissionDecision {
        if let early = earlyResolutions.removeValue(forKey: requestId) {
            os.Logger.permission.info("awaitDecision \(requestId, privacy: .public) returned via early-resolution")
            return early
        }

        os.Logger.permission.info("awaitDecision \(requestId, privacy: .public) waiting (pending=\(self.pending.count))")

        // Backstop: if no resolution happens in 24h, auto-deny so we don't
        // leak the continuation. Cancelled the moment we wake up normally.
        let backstopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.backstopTimeoutSeconds))
            guard !Task.isCancelled else { return }
            os.Logger.permission.warning("awaitDecision \(requestId, privacy: .public) hit 24h backstop")
            await self?.resolve(requestId: requestId, decision: .deny(reason: "Timed out (24h)"))
        }

        let decision = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Race-safe registration: by the time we get here we may
                // already be cancelled OR a resolution may already be sitting
                // in earlyResolutions. Re-check both before parking the
                // continuation, otherwise we'd leak it.
                if Task.isCancelled {
                    continuation.resume(returning: PermissionDecision.deny(reason: "Cancelled before registration"))
                    return
                }
                if let early = earlyResolutions.removeValue(forKey: requestId) {
                    continuation.resume(returning: early)
                    return
                }
                pending[requestId] = continuation
            }
        } onCancel: {
            // Bridge HTTP client disconnected (Claude session ended, OS
            // killed bridge, network blip). Resolve so the UI clears the
            // now-stale card instead of letting it linger.
            //
            // `onCancel` runs from arbitrary context — must hop back to the
            // actor via `Task` to mutate state safely.
            Task { [weak self] in
                await self?.resolve(
                    requestId: requestId,
                    decision: .deny(reason: "Bridge disconnected")
                )
            }
        }

        backstopTask.cancel()
        os.Logger.permission.info("awaitDecision \(requestId, privacy: .public) resolved")
        return decision
    }

    /// Resume a pending decision. Safe to call multiple times — second+
    /// calls are no-ops (guarded by `resolved` set).
    public func resolve(requestId: String, decision: PermissionDecision) {
        guard !resolved.contains(requestId) else { return }
        resolved.insert(requestId)
        // Cap growth — keep a recent slice when exceeding the limit. Sets
        // have undefined order, so this preserves *some* recent IDs but the
        // exact set is non-deterministic; that's acceptable because by the
        // time an evicted ID could see a duplicate resolve, its continuation
        // is long gone (we removed it on the first resolve).
        if resolved.count > 200 {
            resolved = Set(resolved.suffix(100))
        }

        if let continuation = pending.removeValue(forKey: requestId) {
            continuation.resume(returning: decision)
        } else {
            // No awaiter yet — buffer for whoever arrives next, capped to
            // prevent unbounded growth from awaiter-less resolves
            // (e.g., cleanup events for IDs that never went through the
            // bridge path).
            earlyResolutions[requestId] = decision
            if earlyResolutions.count > 200 {
                // Trim oldest by sorted-key-removal. Since we don't track
                // arrival order, fall back to dropping any 50.
                for k in earlyResolutions.keys.prefix(50) {
                    earlyResolutions.removeValue(forKey: k)
                }
            }
        }
    }

    /// Deny all pending requests (e.g., on app quit).
    public func denyAll() {
        os.Logger.permission.info("denyAll resuming \(self.pending.count) continuations")
        for (id, continuation) in pending {
            resolved.insert(id)  // keep the guard so any racing resolve no-ops
            continuation.resume(returning: .deny(reason: "App terminating"))
        }
        pending.removeAll()
        earlyResolutions.removeAll()
        // Note: keep `resolved` populated so a still-running resolve() racing
        // with shutdown still no-ops cleanly. The set is bounded; it'll get
        // trimmed on the next resolve once the actor recycles.
    }
}
