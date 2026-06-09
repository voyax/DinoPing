import Foundation

/// One released version's highlights, shown in the About → What's New sheet
/// and (once an update channel is wired) after the app updates itself.
struct ReleaseNote: Identifiable {
    let version: String
    let date: String
    let highlights: [String]
    var id: String { version }
}

enum ReleaseNotes {
    /// Newest first. Authored alongside CHANGELOG.md on each release.
    static let all: [ReleaseNote] = [
        ReleaseNote(
            version: "0.1.0",
            date: "2026-06-04",
            highlights: [
                "Live Claude Code session monitoring in the notch",
                "Fast process-liveness session counting (~2–4s)",
                "Click a session to jump to its terminal tab",
                "Global hot-keys to toggle, jump, approve, and deny",
                "Settings: shortcuts, sounds, display, launch at login",
            ]
        ),
    ]

    /// Notes strictly newer than `lastSeen` (numeric version compare). Returns
    /// empty on a first install (`lastSeen == nil`) so we don't greet a brand
    /// new user with a "What's New".
    static func notes(since lastSeen: String?) -> [ReleaseNote] {
        guard let lastSeen else { return [] }
        return all.filter {
            $0.version.compare(lastSeen, options: .numeric) == .orderedDescending
        }
    }

    // MARK: - Last-seen version tracking

    private static let lastSeenKey = "AgentPulse.lastSeenVersion"

    static var lastSeenVersion: String? {
        UserDefaults.standard.string(forKey: lastSeenKey)
    }

    /// Record that the user has seen the current version (call after showing
    /// What's New, or on first launch to set the baseline).
    static func markCurrentVersionSeen() {
        UserDefaults.standard.set(AppInfo.version, forKey: lastSeenKey)
    }
}
