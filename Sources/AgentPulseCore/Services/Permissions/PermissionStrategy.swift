import Foundation

/// How AgentPulse persists "Always allow" decisions for a given agent.
///
/// Two-tier model. See `docs/permissions.md` for the architecture
/// rationale and the per-agent decisions.
///
/// - `.native(writer)`: the agent has its own writable allow-list config
///   (Claude's `settings.local.json`, Codex's `rules/` files, etc.). We
///   translate the permission request into the agent's pattern syntax
///   and write it via `writer`. The agent itself enforces the rule
///   before our hook fires next time.
/// - `.notSupported`: no usable external write surface. The UI hides
///   the Always button on cards from these agents.
public enum PermissionStrategy: Sendable {
    case native(any NativeRuleWriter.Type)
    case notSupported

    /// Whether the Always button should be visible in the UI for this strategy.
    public var supportsAlways: Bool {
        switch self {
        case .native: true
        case .notSupported: false
        }
    }
}

/// Per-agent writer that knows how to translate a permission request
/// into that agent's pattern syntax and persist it to the agent's own
/// config file.
///
/// Conformers (one per agent that has a writable allow-list):
/// - `ClaudeCodeRuleWriter`: writes `<cwd>/.claude/settings.local.json`
/// - `CodexCLIRuleWriter`: TODO when Codex hooks land
/// - `GeminiCLIRuleWriter`: TODO when Gemini hooks land
/// - `CursorCLIRuleWriter`: TODO when Cursor CLI hooks land
public protocol NativeRuleWriter: Sendable {
    /// Human-readable pattern shown in the UI helper text below the
    /// buttons (e.g. `"Bash(pnpm prisma:*)"`). Computed without side
    /// effects — safe to call on every UI redraw.
    static func patternPreview(toolName: String, toolInput: [String: Any], cwd: String) -> String

    /// Where the rule will land, used in the helper text suffix
    /// ("in this repo" vs "globally"). Codex flips this based on
    /// whether the project `.codex/` layer is trusted; most writers
    /// just return `.thisRepo` unconditionally.
    static func scopeDescription(toolName: String, toolInput: [String: Any], cwd: String) -> RuleScope

    /// Persist the rule to the agent's config. Idempotent — calling
    /// twice with the same args MUST NOT create a duplicate entry.
    /// Throws on I/O failure; the UI surfaces this as a toast.
    static func writeAllowRule(toolName: String, toolInput: [String: Any], cwd: String) throws
}

public enum RuleScope: Sendable, Equatable {
    case thisRepo
    case globally

    public var helperSuffix: String {
        switch self {
        case .thisRepo: "in this repo"
        case .globally: "globally"
        }
    }
}

/// Errors surfaced from `NativeRuleWriter.writeAllowRule`.
public enum PermissionRuleError: Error, Sendable {
    case unwritablePath(String)
    case malformedExistingConfig(String)
    case ioFailure(String)
}
