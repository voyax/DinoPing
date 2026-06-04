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
        // `.window` (not the default `.menu`) so we get full SwiftUI layout:
        // the native menu templates icons to monochrome and can't render the
        // colored status dots / monogram tiles, and mangles HStack+Spacer rows.
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarView: View {
    let appState: AppState

    var body: some View {
        let sessions = appState.agentManager.activeSessions
        VStack(alignment: .leading, spacing: 1) {
            if sessions.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "moon.zzz")
                    Text("No active agents")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
            } else {
                MenuSectionHeader("Sessions")
                ForEach(sessions) { session in
                    SessionMenuRow(session: session) {
                        // Activating the terminal deactivates AgentPulse, so
                        // the window-style popover dismisses itself.
                        TerminalJumper.jump(to: session)
                    }
                }
            }

            MenuDivider()

            MenuToggleRow(
                title: "Notch Panel",
                systemImage: "macwindow",
                shortcut: "⌥⌘P",
                isOn: Binding(
                    get: { appState.notchPanel?.panelState.isVisible ?? false },
                    set: { on in
                        if on { appState.notchPanel?.transitionToExpanded() }
                        else { appState.notchPanel?.hide() }
                    }
                )
            )

            MenuDivider()

            MenuActionRow(
                title: "Quit AgentPulse", systemImage: "power",
                shortcut: "⌘Q", destructive: true
            ) {
                appState.stop()
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(6)
        .frame(width: 264)
    }
}

// MARK: - Rows

/// A session row — clicking jumps to that session's terminal tab.
private struct SessionMenuRow: View {
    let session: AgentSession
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let badge = StatusBadge.from(session)
        Button(action: action) {
            HStack(spacing: 8) {
                AgentMonogramTile(agent: session.agentKind, size: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.projectName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if let branch = session.branch, !branch.isEmpty {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 8))
                            Text(branch).lineLimit(1)
                            Text("·")
                        }
                        Text(badge.label)
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                statusDot(badge)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowHighlight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Jump to \(session.projectName) in its terminal")
    }

    @ViewBuilder private func statusDot(_ badge: StatusBadge) -> some View {
        if badge.shouldPulse {
            PulsingDot(color: badge.dotColor, size: 7)
        } else {
            Circle().fill(badge.dotColor).frame(width: 7, height: 7)
        }
    }

    private var rowHighlight: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(hovering ? Color.primary.opacity(0.08) : .clear)
    }
}

/// A plain action row (Show/Hide/Quit) styled to match the session rows.
private struct MenuActionRow: View {
    let title: String
    let systemImage: String
    var shortcut: String? = nil
    var destructive: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(title).font(.system(size: 12))
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(destructive ? Color.ap.statusError : .primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering
                        ? (destructive ? Color.ap.statusError.opacity(0.12)
                                        : Color.primary.opacity(0.08))
                        : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A row carrying a macOS switch — same metrics as MenuActionRow so it
/// lines up with the rest of the menu.
private struct MenuToggleRow: View {
    let title: String
    let systemImage: String
    var shortcut: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .frame(width: 16)
            Text(title).font(.system(size: 12))
            Spacer()
            if let shortcut {
                Text(shortcut)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MenuSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }
}

private struct MenuDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
    }
}
