import SwiftUI

public enum AgentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case claudeCode = "claude_code"
    case cursor = "cursor"
    case codexCLI = "codex_cli"
    case geminiCLI = "gemini_cli"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .cursor: "Cursor"
        case .codexCLI: "Codex CLI"
        case .geminiCLI: "Gemini CLI"
        }
    }

    public var iconName: String {
        switch self {
        case .claudeCode: "brain.head.profile"
        case .cursor: "cursorarrow.rays"
        case .codexCLI: "terminal"
        case .geminiCLI: "sparkles"
        }
    }

    public var tintColor: Color {
        switch self {
        case .claudeCode: .orange
        case .cursor: .blue
        case .codexCLI: .green
        case .geminiCLI: .purple
        }
    }
}
