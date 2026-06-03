import Foundation

public enum Constants {
    public static let defaultPort = 21477
    public static let appName = "AgentPulse"
    /// How long an idle/waiting session lingers in the dictionary before
    /// `cleanupStaleSessions` removes it. 30 minutes so a short break
    /// (lunch, meeting) doesn't make the pill vanish.
    public static let sessionTimeoutSeconds: TimeInterval = 1800
    /// How long a `.done` session stays visible before removal — a brief
    /// "session ended" beat for the UI, then it's pruned. Kept short so the
    /// count drops promptly when an instance closes. Combined with the 2s
    /// liveness poll, a closed instance disappears in ~2-4s.
    public static let doneLingerSeconds: TimeInterval = 1
    /// Cadence of the cheap liveness poll (single `ps` snapshot, no lsof).
    public static let livenessPollSeconds: Duration = .seconds(2)
}
