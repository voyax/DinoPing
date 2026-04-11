import Foundation

/// Manages pending permission approvals for the bridge-based flow.
///
/// Safety:
/// - resolve() atomically removes continuation (no double-resume)
/// - Early resolutions are buffered (Fix #2: resolve before awaitDecision)
public actor PermissionService {
    private var pending: [String: CheckedContinuation<PermissionDecision, Never>] = [:]
    /// Buffer for resolutions that arrive before awaitDecision stores the continuation.
    private var earlyResolutions: [String: PermissionDecision] = [:]
    /// IDs that have already been resolved — prevents double-resume from
    /// concurrent "Allow All" + individual card button clicks.
    private var resolved: Set<String> = []

    public init() {}

    /// Block until the user makes a decision in the notch UI.
    public func awaitDecision(for requestId: String) async -> PermissionDecision {
        // Fix #2: check if resolution already arrived
        if let early = earlyResolutions.removeValue(forKey: requestId) {
            return early
        }

        return await withCheckedContinuation { continuation in
            pending[requestId] = continuation
        }
    }

    /// Resume a pending decision. Safe to call multiple times — second+
    /// calls are no-ops (guarded by `resolved` set).
    public func resolve(requestId: String, decision: PermissionDecision) {
        guard !resolved.contains(requestId) else { return }
        resolved.insert(requestId)

        if let continuation = pending.removeValue(forKey: requestId) {
            continuation.resume(returning: decision)
        } else {
            earlyResolutions[requestId] = decision
        }
    }

    /// Deny all pending requests (e.g., on app quit).
    public func denyAll() {
        for (_, continuation) in pending {
            continuation.resume(returning: .deny(reason: "App terminating"))
        }
        pending.removeAll()
        earlyResolutions.removeAll()
        resolved.removeAll()
    }

}
