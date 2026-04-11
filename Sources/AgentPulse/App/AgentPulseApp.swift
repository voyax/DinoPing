import AgentPulseCore
import SwiftUI

@main
struct AgentPulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("AgentPulse", systemImage: "waveform.path.ecg") {
            MenuBarView(appState: appState)
        }
    }
}

struct MenuBarView: View {
    let appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if appState.agentManager.activeSessions.isEmpty {
                Text("No active agents")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appState.agentManager.activeSessions) { session in
                    HStack {
                        Image(systemName: session.agentKind.iconName)
                            .foregroundStyle(session.agentKind.tintColor)
                        Text(session.projectName)
                        Spacer()
                        Text(statusEmoji(session.status))
                    }
                }
            }

            Divider()

            Button("Show Notch Panel") {
                appState.notchPanel?.transitionToExpanded()
            }

            Button("Hide Notch Panel") {
                appState.notchPanel?.hide()
            }

            Divider()

            Button("Quit AgentPulse") {
                appState.stop()
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(4)
    }

    private func statusEmoji(_ status: AgentSession.SessionStatus) -> String {
        switch status {
        case .active: "🟢"
        case .waitingForInput: "🟡"
        case .waitingForPermission: "🟠"
        case .idle: "⚪"
        case .done: "✅"
        case .stopped: "🔴"
        }
    }
}
