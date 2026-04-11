import AgentPulseCore
import SwiftUI

struct AgentStatusRow: View {
    let session: AgentSession

    var body: some View {
        HStack(spacing: 10) {
            // Agent icon
            Image(systemName: session.agentKind.iconName)
                .foregroundStyle(session.agentKind.tintColor)
                .font(.system(size: 14))
                .frame(width: 20)

            // Project name + status
            VStack(alignment: .leading, spacing: 2) {
                Text(session.projectName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let tool = session.currentToolCall {
                    Text(tool.displayDescription)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(statusText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Status indicator
            statusIndicator
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch session.status {
        case .active:
            PulsingDot(color: .green)
        case .waitingForInput:
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 12))
        case .waitingForPermission:
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
        case .idle:
            Circle()
                .fill(.gray.opacity(0.5))
                .frame(width: 8, height: 8)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.blue.opacity(0.7))
                .font(.system(size: 12))
        case .stopped:
            Circle()
                .fill(.red.opacity(0.5))
                .frame(width: 8, height: 8)
        }
    }

    private var statusText: String {
        switch session.status {
        case .active: "Working..."
        case .waitingForInput: "Waiting for input"
        case .waitingForPermission: "Needs permission"
        case .idle: "Idle"
        case .done: "Done"
        case .stopped: "Stopped"
        }
    }
}
