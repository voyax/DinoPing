import Foundation

/// Where the agent is running. Two flavors — terminal apps render the
/// `>_` glyph in the host badge; editor apps render the `</>` glyph.
/// Each `HostKind` has a short `label` for the badge text.
///
/// Detection (e.g. "this Claude Code instance lives in Ghostty") is not
/// wired into the hook bridge yet; until that lands the session falls
/// back to `.terminal` for terminal-native agents and `.vscode`/.`cursorApp`/etc.
/// when the agent is an editor extension (Cline / Cursor).
public enum HostKind: String, Codable, CaseIterable, Sendable, Hashable {
    // Terminals
    case iterm
    case terminal
    case ghostty
    case warp
    case wezterm
    // Editors
    case vscode
    case cursorApp = "cursor_app"
    case zed

    public enum Family: Sendable, Hashable { case terminal, editor }

    public var family: Family {
        switch self {
        case .iterm, .terminal, .ghostty, .warp, .wezterm: .terminal
        case .vscode, .cursorApp, .zed: .editor
        }
    }

    public var label: String {
        switch self {
        case .iterm:     "iTerm"
        case .terminal:  "Terminal"
        case .ghostty:   "Ghostty"
        case .warp:      "Warp"
        case .wezterm:   "WezTerm"
        case .vscode:    "VSCode"
        case .cursorApp: "Cursor"
        case .zed:       "Zed"
        }
    }

    /// Best-guess host when we haven't actually detected it from the
    /// process tree — falls back to the most likely shell for each
    /// agent kind. Replace with real detection once the hook payload
    /// carries the host identifier.
    public static func inferred(from agent: AgentKind) -> HostKind {
        switch agent {
        case .cline:       .vscode
        case .cursor:      .cursorApp
        // Most terminal-native agents — default to iTerm as the
        // statistically-likeliest choice on macOS dev setups.
        case .claudeCode, .codexCLI, .geminiCLI, .aider: .iterm
        }
    }
}
