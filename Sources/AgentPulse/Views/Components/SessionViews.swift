import AgentPulseCore
import SwiftUI

// MARK: - Session Header

struct SessionHeaderView: View {
    let session: AgentSession

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.agentKind.iconName)
                .foregroundStyle(session.agentKind.tintColor)
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 1) {
                Text(session.projectName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(statusText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            BadgePill(text: session.agentKind.displayName, color: session.agentKind.tintColor)

            Button(action: { /* TODO: Terminal jump */ }) {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusText: String {
        switch session.status {
        case .active:
            return session.currentToolCall?.displayDescription ?? "Working..."
        case .waitingForInput: return "Waiting for input"
        case .waitingForPermission: return "Needs permission"
        case .idle: return "Idle"
        case .done: return "Done"
        case .stopped: return "Stopped"
        }
    }
}

// MARK: - Badge Pill

struct BadgePill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }
}

// MARK: - Active Tool View

struct ActiveToolView: View {
    let toolCall: ToolCall

    var body: some View {
        HStack(spacing: 6) {
            PulsingDot(color: .green)

            Text(toolCall.displayDescription)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)

            Spacer()

            if toolCall.endTime == nil {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(elapsedString(from: toolCall.startTime))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func elapsedString(from start: Date) -> String {
        let seconds = Int(Date.now.timeIntervalSince(start))
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}

// MARK: - Compact Session Row

struct CompactSessionRow: View {
    let session: AgentSession

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.agentKind.iconName)
                .foregroundStyle(session.agentKind.tintColor)
                .font(.system(size: 11))

            Text(session.projectName)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)

            Spacer()

            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private var statusColor: Color {
        switch session.status {
        case .active: .green
        case .waitingForPermission: .orange
        case .waitingForInput: .yellow
        case .idle: .gray
        case .done: .blue.opacity(0.7)
        case .stopped: .red.opacity(0.5)
        }
    }
}
