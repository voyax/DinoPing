import AgentPulseCore
import SwiftUI

struct PermissionBanner: View {
    let request: PermissionRequest
    let queuePosition: Int
    let queueTotal: Int
    let onAllow: () -> Void
    let onAlwaysAllow: () -> Void
    let onBypass: () -> Void
    let onDeny: () -> Void

    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Tool action header
            HStack(spacing: 6) {
                Image(systemName: toolIcon)
                    .foregroundStyle(.orange)
                    .font(.system(size: 12, weight: .semibold))

                Text(request.toolTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)

                Spacer()

                if queueTotal > 1 {
                    Text("\(queuePosition) / \(queueTotal)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Content area — diff or command
            contentView
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            HStack(spacing: 6) {
                PermissionButton(title: "Deny", shortcut: "^N", style: .deny, action: onDeny)
                PermissionButton(title: "Allow", shortcut: "^Y", style: .allow, action: onAllow)
                PermissionButton(title: "Always", shortcut: "^A", style: .alwaysAllow, action: onAlwaysAllow)
                PermissionButton(title: "Bypass", shortcut: "^B", style: .bypass, action: onBypass)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.18), lineWidth: 1)
        )
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : -8)
        .animation(.spring(duration: 0.3), value: appeared)
        .onAppear { appeared = true }
    }

    @ViewBuilder
    private var contentView: some View {
        if request.hasDiff, let old = request.diffOldString, let new = request.diffNewString {
            DiffView(
                filePath: request.filePath ?? "unknown",
                oldString: old,
                newString: new
            )
        } else if request.toolName == "Bash", let cmd = request.bashCommand {
            HStack(alignment: .top, spacing: 0) {
                Text("$ ")
                    .foregroundStyle(.green.opacity(0.6))
                Text(cleanCommand(cmd))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(3)
            }
            .font(.system(size: 10.5, design: .monospaced))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else if request.toolName == "Write" {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.fileName ?? "?")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))

                if let content = request.writeContent {
                    Text(String(content.prefix(200)))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.green.opacity(0.8))
                        .lineLimit(5)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Text(request.displayDescription)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(2)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var toolIcon: String {
        switch request.toolName {
        case "Bash": "terminal"
        case "Edit": "pencil.line"
        case "Write": "doc.badge.plus"
        case "Read": "doc.text"
        case "Glob", "Grep": "magnifyingglass"
        default: "exclamationmark.triangle"
        }
    }

    /// Strip leading comment lines and trailing whitespace; join multi-line into one
    private func cleanCommand(_ cmd: String) -> String {
        let lines = cmd.components(separatedBy: "\n")
        let nonComment = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }
        return nonComment.joined(separator: " && ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Permission Button

struct PermissionButton: View {
    let title: String
    let shortcut: String
    let style: Style
    let action: () -> Void

    enum Style {
        case deny, allow, alwaysAllow, bypass

        var bgColor: Color {
            switch self {
            case .deny: .white.opacity(0.08)
            case .allow: .white.opacity(0.1)
            case .alwaysAllow: .blue.opacity(0.25)
            case .bypass: .red.opacity(0.25)
            }
        }

        var fgColor: Color {
            switch self {
            case .deny: .white.opacity(0.8)
            case .allow: .white.opacity(0.9)
            case .alwaysAllow: .blue
            case .bypass: .red
            }
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Text(shortcut)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .opacity(0.5)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(style.bgColor)
            .foregroundStyle(style.fgColor)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}
