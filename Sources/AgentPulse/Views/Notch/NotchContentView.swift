import AgentPulseCore
import SwiftUI

struct NotchContentView: View {
    let agentManager: AgentManager
    let panelState: NotchPanelState

    private var displayState: NotchDisplayState { panelState.displayState }
    private var hasNotch: Bool { panelState.hasNotch }
    private var isExpanded: Bool { displayState == .expanded }
    private var isCompact: Bool { displayState == .compact }

    // MARK: - Animation curves

    private static let openAnimation: Animation = .spring(response: 0.42, dampingFraction: 0.78)
    private static let closeAnimation: Animation = .smooth(duration: 0.32)
    private static let conversionAnimation: Animation = .spring(response: 0.4, dampingFraction: 0.84)

    private var transitionAnimation: Animation {
        switch displayState {
        case .dormant: return Self.closeAnimation
        case .compact: return Self.conversionAnimation
        case .expanded: return Self.openAnimation
        }
    }

    // MARK: - Animatable shape parameters (single source: SilhouetteSizing)

    private var topRadius: CGFloat {
        SilhouetteSizing.topRadius(state: displayState, hasNotch: hasNotch)
    }

    private var bottomRadius: CGFloat {
        SilhouetteSizing.bottomRadius(state: displayState, hasNotch: hasNotch)
    }

    // MARK: - Body
    //
    // Architecture: the silhouette size is **explicitly** state-driven, not
    // content-driven. The black NotchShape and the inner content both share
    // the same `silhouetteSize`. SwiftUI animates the size and the
    // animatable NotchShape interpolates its bezier path in lockstep.
    //
    // Why not let content drive size? Because during an `if/else` swap the
    // outgoing view still occupies layout space briefly, leaving the
    // silhouette stuck at the old (larger) size for the duration of the
    // collapse animation — the "ghost frame" the user reported.

    var body: some View {
        ZStack(alignment: .top) {
            // The visible black silhouette
            NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
                .fill(Color.black)

            // Content overlaid on top, clipped to the exact same shape so it
            // can never spill outside the curve while transitioning.
            Group {
                if isCompact {
                    compactView
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .top)))
                } else if isExpanded {
                    expandedView
                        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
                }
            }
            .frame(width: silhouetteWidth, height: silhouetteHeight, alignment: .top)
            .clipShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius))
        }
        // Constrain to silhouette size FIRST so the tap gesture and shape
        // hit-test below operate on the small visible region, not the whole
        // 540×420 panel canvas.
        .frame(width: silhouetteWidth, height: silhouetteHeight)
        .contentShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius))
        // NOTE: no `.onTapGesture` here — it used to call handleTap() to
        // toggle compact↔expanded, but it also intercepted clicks on child
        // Buttons (like the ↗ terminal-jump button) and prevented them from
        // firing. Collapse is handled by hover-out via the NSEvent monitor.
        //
        // NOTE: no `.onHover` here. Hover detection lives entirely in
        // `NotchPanel.updateMouseState` (NSEvent monitor). Adding SwiftUI
        // `.onHover` on this view used to compete with the NSEvent path —
        // its content shape was the *outer* frame below, so the cursor
        // anywhere in the 540×420 panel area was reported as "hovering"
        // and the expand→collapse cycle never settled.
        .shadow(
            color: .black.opacity(isExpanded ? 0.45 : 0.25),
            radius: isExpanded ? 18 : 6,
            y: isExpanded ? 8 : 2
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(transitionAnimation, value: displayState)
        // The silhouette also has to animate when content count changes,
        // otherwise a new card "snaps" into the silhouette without easing.
        .animation(.smooth(duration: 0.28), value: agentManager.activeSessions.count)
        .animation(.smooth(duration: 0.28), value: agentManager.pendingPermissions.count)
    }

    /// Single source of truth for the visible silhouette size — both this
    /// view (for drawing) and `NotchPanel.currentHitTestRect` (for click-
    /// through hit testing) read the same `SilhouetteSizing` so the hover
    /// trigger area can never extend beyond the visible black region.
    private var silhouetteSize: CGSize {
        SilhouetteSizing.size(
            state: displayState,
            hasNotch: hasNotch,
            notchWidth: panelState.notchWidth,
            notchHeight: panelState.notchHeight,
            sessionCount: agentManager.activeSessions.count,
            permissionCount: agentManager.pendingPermissions.count
        )
    }

    private var silhouetteWidth: CGFloat { silhouetteSize.width }
    private var silhouetteHeight: CGFloat { silhouetteSize.height }

    // MARK: - Compact (the pill)

    @ViewBuilder
    private var compactView: some View {
        let sessions = agentManager.activeSessions
        let permCount = agentManager.pendingPermissions.count

        HStack(spacing: 7) {
            Circle()
                .fill(compactStatusColor(sessions: sessions, permCount: permCount))
                .frame(width: 6, height: 6)

            Text(compactText(sessions: sessions, permCount: permCount))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    // MARK: - Expanded (cards)

    @ViewBuilder
    private var expandedView: some View {
        let sessions = sortedSessions
        let permissions = agentManager.pendingPermissions

        // Reserve room for the notch silhouette at the top so the first card
        // doesn't get cropped by the curve.
        let topInset: CGFloat = hasNotch ? panelState.notchHeight + 4 : 8

        if sessions.isEmpty && permissions.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.3))
                Text("No active agents")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, topInset)
            .padding(.bottom, 12)
        } else {
            // ScrollView so >5 cards stay reachable instead of being clipped
            // by the silhouette's max height.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    // Permissions first (highest priority)
                    if !permissions.isEmpty {
                        // Bulk actions when 2+ permissions queued
                        if permissions.count >= 2 {
                            HStack(spacing: 8) {
                                Button {
                                    for req in permissions { agentManager.approvePermission(id: req.id) }
                                } label: {
                                    Label("Allow All (\(permissions.count))", systemImage: "checkmark.circle")
                                        .font(.system(size: 11, weight: .medium))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                        .background(.white.opacity(0.1))
                                        .foregroundStyle(.green)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)

                                Button {
                                    for req in permissions { agentManager.denyPermission(id: req.id) }
                                } label: {
                                    Label("Deny All", systemImage: "xmark.circle")
                                        .font(.system(size: 11, weight: .medium))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                        .background(.white.opacity(0.08))
                                        .foregroundStyle(.red.opacity(0.8))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        ForEach(Array(permissions.enumerated()), id: \.element.id) { i, req in
                            PermissionBanner(
                                request: req, queuePosition: i + 1, queueTotal: permissions.count,
                                onAllow: { agentManager.approvePermission(id: req.id) },
                                onAlwaysAllow: {
                                    // Save rule with the specific command/path,
                                    // not a blanket nil pattern that matches everything.
                                    let input = req.toolInput.mapValues { $0.value }
                                    let pattern = AllowRules.primaryArg(
                                        toolName: req.toolName, input: input
                                    )
                                    AllowRules.add(.init(
                                        toolName: req.toolName,
                                        pattern: pattern
                                    ))
                                    agentManager.approvePermission(id: req.id)
                                },
                                onBypass: { agentManager.bypassPermission(id: req.id) },
                                onDeny: { agentManager.denyPermission(id: req.id) }
                            )
                        }
                    }

                    // Session cards (no dividers — each card has its own
                    // surface so the spacing between them does the separation)
                    ForEach(sessions, id: \.id) { session in
                        SessionCard(session: session)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, topInset + 6)
                .padding(.bottom, 12)
            }
            .frame(width: 380)
            // Don't bounce off the top edge — that visually fights the notch
            // curve and feels wrong.
            .scrollBounceBehavior(.basedOnSize)
            // Soft fade at the bottom hints there's more to scroll.
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.92),
                        .init(color: .clear, location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    // MARK: - Helpers

    private var sortedSessions: [AgentSession] {
        agentManager.activeSessions.sorted { a, b in
            sortPriority(a) < sortPriority(b)
        }
    }

    private func sortPriority(_ s: AgentSession) -> Int {
        switch s.status {
        case .waitingForPermission: 0
        case .active: 1
        case .waitingForInput: 2
        case .idle: 3
        case .done: 4
        case .stopped: 5
        }
    }

    private func compactStatusColor(sessions: [AgentSession], permCount: Int) -> Color {
        if permCount > 0 { return .orange }
        if sessions.contains(where: { $0.status == .active }) { return .green }
        return .white.opacity(0.4)
    }

    private func compactText(sessions: [AgentSession], permCount: Int) -> String {
        if permCount > 0 { return "\(permCount) needs input" }
        if sessions.isEmpty { return "No agents" }
        let total = sessions.count
        let active = sessions.filter { $0.status == .active }.count
        if active > 0 && active < total { return "\(active)/\(total) active" }
        if active == total { return total == 1 ? "1 working" : "\(total) working" }
        return total == 1 ? "1 idle" : "\(total) idle"
    }
}

// MARK: - Session Card

struct SessionCard: View {
    let session: AgentSession
    @State private var hovering = false
    @State private var jumpHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Small agent icon — just enough to hint at agent type without
            // dominating the card. 20pt feels proportional to 13pt title.
            ZStack {
                Circle()
                    .fill(session.agentKind.tintColor.opacity(0.14))
                Image(systemName: session.agentKind.iconName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(session.agentKind.tintColor)
            }
            .frame(width: 22, height: 22)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 5) {
                // Row 1: project name, status dot, time
                HStack(alignment: .center, spacing: 7) {
                    Text(session.projectName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Circle()
                        .fill(statusColor)
                        .frame(width: 5, height: 5)

                    Spacer(minLength: 4)

                    Text(elapsedText)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.32))
                }

                // Row 2: prompt body — the hero of the card
                if let prompt = session.lastUserPrompt, !prompt.isEmpty {
                    Text(prompt)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Idle — no recent prompt")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.32))
                        .italic()
                }

                // When active: show tool call activity feed + counter
                // When idle/waiting: show Claude's last reply (what it concluded)
                if session.status == .active, !session.recentTools.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ActivityFeedView(tools: Array(session.recentTools.prefix(3)))
                        if session.recentTools.count > 3 {
                            Text("\(session.recentTools.count) tool calls so far")
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                    }
                    .padding(.top, 2)
                } else if let reply = session.lastAssistantMessage, !reply.isEmpty {
                    Text(reply)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(2)
                        .truncationMode(.tail)
                }

                // Row 3: agent kind + status as a single subtle line
                HStack(spacing: 6) {
                    Text(session.agentKind.displayName)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(session.agentKind.tintColor.opacity(0.95))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(session.agentKind.tintColor.opacity(0.16))
                        .clipShape(Capsule())

                    Text("·")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.3))

                    Text(statusText)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                .padding(.top, 1)
            }

            // Terminal jump button — only visible on hover.
            Button(action: { TerminalJumper.jump(to: session) }) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(jumpHovering ? 0.95 : 0.55))
                    .padding(6)
                    .background(
                        Circle().fill(.white.opacity(jumpHovering ? 0.12 : 0.0))
                    )
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .onHover { jumpHovering = $0 }
            .help("Bring the terminal running this agent to the front")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(hovering ? 0.09 : 0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 0.5)
                )
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

}

// MARK: - Activity Feed

struct ActivityFeedView: View {
    let tools: [ToolCall]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(tools) { tool in
                ActivityRow(tool: tool)
            }
        }
    }
}

struct ActivityRow: View {
    let tool: ToolCall

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: iconName)
                .font(.system(size: 9))
                .foregroundStyle(tool.status == .running ? .green.opacity(0.8) : .white.opacity(0.5))
                .frame(width: 12)
            Text(tool.displayDescription)
                .font(.system(size: 10))
                .foregroundStyle(tool.status == .running ? .white.opacity(0.8) : .white.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let duration = toolDuration {
                Text(duration)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.3))
            }
            statusIcon
        }
    }

    private var toolDuration: String? {
        guard let end = tool.endTime else {
            // Still running — show elapsed
            let seconds = Int(Date.now.timeIntervalSince(tool.startTime))
            return seconds >= 1 ? "\(seconds)s" : nil
        }
        let seconds = Int(end.timeIntervalSince(tool.startTime))
        if seconds < 1 { return nil }  // instant — don't clutter
        return "\(seconds)s"
    }

    private var iconName: String {
        switch tool.toolName {
        case "Bash": "terminal"
        case "Read": "doc.text"
        case "Edit": "pencil.line"
        case "Write": "doc.badge.plus"
        case "Glob", "Grep": "magnifyingglass"
        case "Agent": "person.2"
        default: "gearshape"
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch tool.status {
        case .succeeded:
            Image(systemName: "checkmark")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.green.opacity(0.6))
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.red.opacity(0.6))
        case .running:
            Circle()
                .fill(.green)
                .frame(width: 5, height: 5)
        }
    }
}

extension SessionCard {
    private var statusColor: Color {
        switch session.status {
        case .active: .green
        case .waitingForPermission: .orange
        case .waitingForInput: .yellow.opacity(0.8)
        case .idle: .gray
        case .done: .blue.opacity(0.7)
        case .stopped: .red.opacity(0.5)
        }
    }

    private var statusText: String {
        switch session.status {
        case .active:
            // Show current tool call if running, otherwise generic "Working..."
            if let tool = session.currentToolCall, tool.status == .running {
                return tool.displayDescription
            }
            return "Working..."
        case .waitingForInput: return "Waiting for input"
        case .waitingForPermission: return "Needs permission"
        case .idle: return "Idle"
        case .done: return "Done"
        case .stopped: return "Stopped"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private var elapsedText: String {
        let ref = session.lastActiveTime ?? session.lastEventTime
        let seconds = max(0, Int(Date.now.timeIntervalSince(ref)))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        let days = seconds / 86400
        if days == 1 { return "yesterday" }
        if days < 7 { return "\(days)d ago" }
        return Self.dateFormatter.string(from: ref)
    }
}
