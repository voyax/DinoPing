import AppKit
import Foundation

/// Persisted "which physical display should the notch panel live on?"
/// preference. Stored in UserDefaults so it survives relaunches.
///
/// The value we persist is the screen's `localizedName` (e.g.
/// "Built-in Retina Display", "DELL U2720Q"). Names are stable enough across
/// reboots and unlike `displayID` they don't change when the user re-plugs
/// a monitor with a different USB-C port.
enum DisplayPreference {
    private static let key = "AgentPulse.preferredDisplayName"

    /// Returns the user's preferred screen name, or nil if "Auto".
    static var preferredName: String? {
        UserDefaults.standard.string(forKey: key)
    }

    /// nil = auto (notch detection / fallback), otherwise pin to that screen.
    static func set(_ name: String?) {
        if let name {
            UserDefaults.standard.set(name, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Resolves a screen for the current preference, falling back to nil if
    /// the preferred display isn't connected right now (caller should then
    /// fall back to its own auto-detect logic).
    static func resolveScreen() -> NSScreen? {
        guard let name = preferredName else { return nil }
        return NSScreen.screens.first { $0.localizedName == name }
    }
}
