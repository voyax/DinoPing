import AppKit
import Carbon.HIToolbox

/// A captured key combination, stored as a Carbon virtual key-code plus a
/// Carbon modifier mask (`cmdKey | optionKey | …`) so it feeds straight into
/// `RegisterEventHotKey`.
struct HotKeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    /// Carbon modifier mask built from a Cocoa `NSEvent` flag set.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.option)  { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.shift)   { mask |= UInt32(shiftKey) }
        return mask
    }

    /// At least one of ⌘ / ⌥ / ⌃ — a bare key (or Shift-only) is rejected as
    /// a global hot-key because it would fire constantly while typing.
    var hasRequiredModifier: Bool {
        carbonModifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }

    /// Human-readable form, Apple order ⌃⌥⇧⌘ then the key, e.g. "⌥⌘P".
    var display: String {
        var out = ""
        if carbonModifiers & UInt32(controlKey) != 0 { out += "⌃" }
        if carbonModifiers & UInt32(optionKey)  != 0 { out += "⌥" }
        if carbonModifiers & UInt32(shiftKey)   != 0 { out += "⇧" }
        if carbonModifiers & UInt32(cmdKey)     != 0 { out += "⌘" }
        out += Self.keyName(keyCode)
        return out
    }

    /// Symbol/letter for a virtual key-code. Covers the keys a user is
    /// likely to bind; anything else shows as a numeric fallback.
    static func keyName(_ code: UInt32) -> String {
        if let name = keyNames[code] { return name }
        return "key\(code)"
    }

    private static let keyNames: [UInt32: String] = [
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F",
        0x05: "G", 0x04: "H", 0x22: "I", 0x26: "J", 0x28: "K", 0x25: "L",
        0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P", 0x0C: "Q", 0x0F: "R",
        0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X",
        0x10: "Y", 0x06: "Z",
        0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5", 0x16: "6",
        0x1A: "7", 0x1C: "8", 0x19: "9", 0x1D: "0",
        0x31: "Space", 0x24: "↩", 0x33: "⌫", 0x75: "⌦", 0x30: "⇥", 0x35: "⎋",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        0x73: "↖", 0x77: "↘", 0x74: "⇞", 0x79: "⇟",
        0x1B: "-", 0x18: "=", 0x21: "[", 0x1E: "]", 0x2A: "\\",
        0x29: ";", 0x27: "'", 0x2B: ",", 0x2F: ".", 0x2C: "/", 0x32: "`",
    ]
}

/// The user-rebindable global actions.
enum HotKeyAction: String, CaseIterable, Identifiable {
    case togglePanel
    case jumpToWaiting
    case approve
    case deny

    var id: String { rawValue }

    var title: String {
        switch self {
        case .togglePanel:  "Toggle Notch Panel"
        case .jumpToWaiting: "Jump to Waiting Session"
        case .approve:      "Approve Permission"
        case .deny:         "Deny Permission"
        }
    }

    var subtitle: String {
        switch self {
        case .togglePanel:  "Show or hide the notch panel"
        case .jumpToWaiting: "Focus the terminal of the next session needing you"
        case .approve:      "Approve the front pending permission"
        case .deny:         "Deny the front pending permission"
        }
    }

    var defaultCombo: HotKeyCombo {
        let optCmd = UInt32(optionKey | cmdKey)
        switch self {
        case .togglePanel:   return HotKeyCombo(keyCode: UInt32(kVK_ANSI_P), carbonModifiers: optCmd)
        case .jumpToWaiting: return HotKeyCombo(keyCode: UInt32(kVK_ANSI_J), carbonModifiers: optCmd)
        case .approve:       return HotKeyCombo(keyCode: UInt32(kVK_Return), carbonModifiers: optCmd)
        case .deny:          return HotKeyCombo(keyCode: UInt32(kVK_Delete), carbonModifiers: optCmd)
        }
    }

    fileprivate var defaultsKey: String { "AgentPulse.hotkey.\(rawValue)" }
}

/// Persisted, observable store of the four global hot-key bindings. Mutating
/// a binding saves it and fires `onChange` so `AppState` re-registers.
@MainActor
@Observable
final class HotKeySettings {
    static let shared = HotKeySettings()

    /// Set by AppState; invoked whenever a binding changes.
    @ObservationIgnored var onChange: (() -> Void)?

    private var combos: [HotKeyAction: HotKeyCombo] = [:]

    private init() {
        for action in HotKeyAction.allCases {
            combos[action] = Self.load(action) ?? action.defaultCombo
        }
    }

    func combo(for action: HotKeyAction) -> HotKeyCombo {
        combos[action] ?? action.defaultCombo
    }

    func set(_ combo: HotKeyCombo, for action: HotKeyAction) {
        combos[action] = combo
        Self.save(combo, action)
        onChange?()
    }

    func reset(_ action: HotKeyAction) {
        combos[action] = action.defaultCombo
        UserDefaults.standard.removeObject(forKey: action.defaultsKey)
        onChange?()
    }

    func isDefault(_ action: HotKeyAction) -> Bool {
        combo(for: action) == action.defaultCombo
    }

    /// The action already bound to `combo`, if any (excluding `action`) — used
    /// to reject a duplicate so two shortcuts never collide.
    func conflict(for combo: HotKeyCombo, excluding action: HotKeyAction) -> HotKeyAction? {
        HotKeyAction.allCases.first { $0 != action && self.combo(for: $0) == combo }
    }

    var allBindings: [(action: HotKeyAction, combo: HotKeyCombo)] {
        HotKeyAction.allCases.map { ($0, combo(for: $0)) }
    }

    private static func load(_ action: HotKeyAction) -> HotKeyCombo? {
        guard let data = UserDefaults.standard.data(forKey: action.defaultsKey) else { return nil }
        return try? JSONDecoder().decode(HotKeyCombo.self, from: data)
    }

    private static func save(_ combo: HotKeyCombo, _ action: HotKeyAction) {
        if let data = try? JSONEncoder().encode(combo) {
            UserDefaults.standard.set(data, forKey: action.defaultsKey)
        }
    }
}
