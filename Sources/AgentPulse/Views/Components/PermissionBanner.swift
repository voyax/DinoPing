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
            // Tool action header. The age badge is critical at our 24h
            // permission timeout — a user who comes back tomorrow needs to
            // see "8h ago" before clicking Allow on a forgotten `rm -rf`.
            // TimelineView ticks every minute so the age stays current
            // without us tracking observation manually.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                HStack(spacing: 6) {
                    Image(systemName: toolIcon)
                        .foregroundStyle(ageColor(now: context.date))
                        .font(.system(size: 12, weight: .semibold))

                    Text(request.toolTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ageColor(now: context.date))

                    Spacer()

                    if queueTotal > 1 {
                        Text("\(queuePosition) / \(queueTotal)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                    }

                    Text(ageText(now: context.date))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(ageColor(now: context.date).opacity(0.85))
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)
            }

            // Content area — diff or command
            contentView
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            // Two button groups separated by a divider. The right group
            // (Always / Bypass) writes persistent state — Always saves a
            // rule, Bypass disables future prompts for this tool. They're
            // kept visually adjacent (deliberately, so they're discoverable)
            // but spaced away from the primary Allow/Deny pair so a fast
            // muscle-memory click on "Allow" doesn't slip onto Bypass.
            HStack(spacing: 6) {
                PermissionButton(title: "Deny", shortcut: "^N", style: .deny, action: onDeny)
                PermissionButton(title: "Allow", shortcut: "^Y", style: .allow, action: onAllow)

                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 1, height: 22)
                    .padding(.horizontal, 2)

                PermissionButton(title: "Always", shortcut: "^A", style: .alwaysAllow, action: onAlwaysAllow)
                PermissionButton(title: "Bypass", shortcut: "^B", style: .bypass, action: onBypass)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .background(
            // Solid fill + left accent bar; no stroke. Mirrors the visual
            // grammar of QuestionBanner so both read as "child of the
            // session card" instead of competing free-floating cards.
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.orange.opacity(0.08))
                Rectangle()
                    .fill(Color.orange.opacity(0.55))
                    .frame(width: 2.5)
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 10, bottomLeadingRadius: 10,
                            bottomTrailingRadius: 0, topTrailingRadius: 0
                        )
                    )
            }
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
            // CRITICAL: render command verbatim — whatever Claude is going to
            // run is what the user gets to see, byte for byte.
            bashCommandView(cmd)
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

    private static let maxVisibleLines = 8

    @ViewBuilder
    private func bashCommandView(_ cmd: String) -> some View {
        let lines = cmd.components(separatedBy: "\n")
        let truncated = lines.count > Self.maxVisibleLines
        let visibleCmd = truncated
            ? lines.prefix(Self.maxVisibleLines).joined(separator: "\n")
            : cmd

        VStack(alignment: .leading, spacing: 4) {
            ScrollView([.horizontal], showsIndicators: true) {
                HStack(alignment: .top, spacing: 0) {
                    Text("$ ")
                        .foregroundStyle(.green.opacity(0.6))
                    Text(visibleCmd)
                        .foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: true, vertical: true)
                }
                .font(.system(size: 10.5, design: .monospaced))
            }

            if truncated {
                Text("… +\(lines.count - Self.maxVisibleLines) more lines")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Compact age text. "now" / "5m" / "2h" / "1d". Updates from a
    /// TimelineView tick.
    private func ageText(now: Date) -> String {
        let elapsed = Int(now.timeIntervalSince(request.receivedAt))
        if elapsed < 60 { return "now" }
        if elapsed < 3600 { return "\(elapsed / 60)m" }
        if elapsed < 86400 { return "\(elapsed / 3600)h" }
        return "\(elapsed / 86400)d"
    }

    /// Tint the orange-by-default header to amber/red as the request ages,
    /// signaling "this is stale — re-confirm what you're approving."
    private func ageColor(now: Date) -> Color {
        let elapsed = now.timeIntervalSince(request.receivedAt)
        if elapsed < 600 { return .orange }                  // <10min: fresh
        if elapsed < 3600 { return Color(red: 0.95, green: 0.55, blue: 0.2) }  // <1h: amber
        return Color(red: 0.95, green: 0.35, blue: 0.25)     // ≥1h: red — likely forgotten
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
            // Ghost: no fill, just text. Bypass permanently disables future
            // prompts for this tool type — it should look LESS prominent than
            // the safe Deny/Allow pair, not MORE. The old red fill was more
            // eye-catching than Deny's gray, inverting the risk hierarchy.
            case .bypass: .clear
            }
        }

        var fgColor: Color {
            switch self {
            case .deny: .white.opacity(0.8)
            case .allow: .white.opacity(0.9)
            case .alwaysAllow: .blue
            case .bypass: .red.opacity(0.6)
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
