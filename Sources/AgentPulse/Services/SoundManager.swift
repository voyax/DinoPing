import AppKit

@MainActor
final class SoundManager {
    static let shared = SoundManager()

    enum Alert: String, CaseIterable, Sendable {
        case permissionNeeded = "permission_needed"  // Tier 1: auto-expand + sound
        case taskComplete = "task_complete"           // Tier 2: agent finished
        case agentStarted = "agent_started"           // Tier 2: new agent detected
        case agentError = "agent_error"               // Tier 2: agent crashed/failed

        var systemSoundName: NSSound.Name {
            switch self {
            case .permissionNeeded: NSSound.Name("Funk")
            case .taskComplete: NSSound.Name("Glass")
            case .agentStarted: NSSound.Name("Pop")
            case .agentError: NSSound.Name("Basso")
            }
        }
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "soundEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "soundEnabled") }
    }

    /// Throttle: max 1 sound per 5 seconds to prevent audio spam
    private var lastPlayTime: Date = .distantPast
    private let throttleInterval: TimeInterval = 5

    private init() {
        if UserDefaults.standard.object(forKey: "soundEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "soundEnabled")
        }
    }

    func play(_ alert: Alert) {
        guard isEnabled else { return }

        // Tier 1 (permissionNeeded) always plays, others are throttled
        if alert != .permissionNeeded {
            let now = Date.now
            guard now.timeIntervalSince(lastPlayTime) >= throttleInterval else { return }
            lastPlayTime = now
        }

        NSSound(named: alert.systemSoundName)?.play()
    }
}
