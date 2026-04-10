import Foundation

public enum Constants {
    public static let defaultPort = 21477
    public static let appName = "AgentPulse"
    /// How long an idle/waiting session lingers in the dictionary before
    /// `cleanupStaleSessions` removes it. 30 minutes so a short break
    /// (lunch, meeting) doesn't make the pill vanish.
    public static let sessionTimeoutSeconds: TimeInterval = 1800
}
