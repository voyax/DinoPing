import SwiftUI

/// Which AI is doing the work. Per the AgentPulse design spec each agent
/// has a brand-ish color, a short label, and a 2-character monogram used
/// as the visual anchor on every session card.
public enum AgentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case claudeCode  = "claude_code"
    case codexCLI    = "codex_cli"
    case cursor      = "cursor"
    case geminiCLI   = "gemini_cli"
    case aider       = "aider"
    case cline       = "cline"

    public var id: String { rawValue }

    /// Full label — used in tooltips and onboarding copy.
    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codexCLI:   "Codex"
        case .cursor:     "Cursor"
        case .geminiCLI:  "Gemini CLI"
        case .aider:      "Aider"
        case .cline:      "Cline"
        }
    }

    /// Short label — fits on a session-card badge.
    public var shortLabel: String {
        switch self {
        case .claudeCode: "Claude"
        case .codexCLI:   "Codex"
        case .cursor:     "Cursor"
        case .geminiCLI:  "Gemini"
        case .aider:      "Aider"
        case .cline:      "Cline"
        }
    }

    /// 2-character monogram for the colored agent tile (16×16 rounded
    /// square at the leading edge of each session card).
    public var monogram: String {
        switch self {
        case .claudeCode: "CC"
        case .codexCLI:   "CX"
        case .cursor:     "CR"
        case .geminiCLI:  "GM"
        case .aider:      "AI"
        case .cline:      "CL"
        }
    }

    /// SF Symbol — legacy fallback used wherever the monogram tile isn't
    /// rendered. Kept so existing call sites don't break.
    public var iconName: String {
        switch self {
        case .claudeCode: "brain.head.profile"
        case .codexCLI:   "terminal"
        case .cursor:     "cursorarrow.rays"
        case .geminiCLI:  "sparkles"
        case .aider:      "wand.and.stars"
        case .cline:      "chevron.left.forwardslash.chevron.right"
        }
    }

    /// How AgentPulse persists "Always allow" rules for sessions from
    /// this agent. See `docs/permissions.md` for the rationale behind
    /// each decision. Per-agent native writers go in
    /// `Sources/AgentPulseCore/Services/Permissions/`.
    ///
    /// Currently only Claude Code is hook-wired — the others stay
    /// `.notSupported` until their `installXxxHooks()` lands in
    /// `HookInstaller`, at which point flip them to
    /// `.native(XxxRuleWriter.self)`.
    public var permissionStrategy: PermissionStrategy {
        switch self {
        case .claudeCode: .native(ClaudeCodeRuleWriter.self)
        case .codexCLI:   .notSupported    // TODO: .native(CodexCLIRuleWriter.self) when hooks land
        case .geminiCLI:  .notSupported    // TODO: .native(GeminiCLIRuleWriter.self) when hooks land
        case .cursor:     .notSupported    // see docs/permissions.md "Cursor caveat"
        case .cline:      .notSupported    // no documented external write API
        case .aider:      .notSupported    // blanket --yes-always only
        }
    }

    /// Brand color — used for the monogram tile fill and any per-agent
    /// accent. Exact hex from design spec.
    public var tintColor: Color {
        switch self {
        case .claudeCode: Color(red: 0.851, green: 0.467, blue: 0.341)  // #d97757
        case .codexCLI:   Color(red: 0.063, green: 0.639, blue: 0.498)  // #10a37f
        case .cursor:     Color(red: 0.490, green: 0.827, blue: 0.988)  // #7dd3fc
        case .geminiCLI:  Color(red: 0.259, green: 0.522, blue: 0.957)  // #4285f4
        case .aider:      Color(red: 0.655, green: 0.545, blue: 0.976)  // #a78bfa
        case .cline:      Color(red: 0.984, green: 0.749, blue: 0.141)  // #fbbf24
        }
    }
}
