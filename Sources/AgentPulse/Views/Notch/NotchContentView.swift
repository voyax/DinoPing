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
    //
    // Design spec: `apIslandExpand .32s cubic-bezier(.34, 1.5, .55, 1)` —
    // a slight overshoot spring. SwiftUI's `.spring(response: 0.32,
    // dampingFraction: 0.6)` approximates that bezier curve. Close (1→2)
    // and compact↔compact conversions use a tighter, non-bouncy easing
    // so they don't feel "wobbly" when nothing dramatic is happening.

    private static let openAnimation: Animation = .spring(response: 0.32, dampingFraction: 0.6)
    private static let closeAnimation: Animation = .smooth(duration: 0.28)
    private static let conversionAnimation: Animation = .spring(response: 0.34, dampingFraction: 0.78)

    private var transitionAnimation: Animation {
        switch displayState {
        case .dormant: return Self.closeAnimation
        case .compact: return Self.conversionAnimation
        case .expanded: return Self.openAnimation
        }
    }

    // MARK: - Animatable shape parameters (single source: SilhouetteSizing)

    private var shoulder: CGFloat {
        SilhouetteSizing.shoulder(state: displayState, hasNotch: hasNotch)
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

    /// Number of sessions awaiting user response (permission or question).
    /// Drives the ACTION-state visual upgrades on the silhouette.
    private var waitingCount: Int {
        agentManager.activeSessions.filter {
            $0.pendingPermission != nil || $0.pendingQuestion != nil
        }.count
    }

    private var isActionState: Bool { waitingCount > 0 }

    var body: some View {
        ZStack(alignment: .top) {
            // ACTION halo — accent-colored duplicate of the silhouette,
            // sitting BEHIND the main fill with a blur so it reads as a
            // soft warm glow around the pill / card. Toggled on whenever
            // any session needs the user.
            if isActionState {
                NotchShape(bottomRadius: bottomRadius, shoulder: shoulder)
                    .fill(Color.ap.accentDefault)
                    .opacity(isExpanded ? 0.32 : 0.55)
                    .blur(radius: isExpanded ? 4 : 3)
                    .allowsHitTesting(false)
            }

            // Silhouette body fill. Compact/dormant pill is pure black —
            // it sits against a screen-black notch and must read as one
            // continuous shape. The expanded card gets a subtle vertical
            // gradient so it doesn't look flat at 380pt tall.
            NotchShape(bottomRadius: bottomRadius, shoulder: shoulder)
                .fill(silhouetteFill)

            // Silhouette stroke. White hairline normally; accent in ACTION
            // so the entire panel reads warm-orange-edged.
            NotchShape(bottomRadius: bottomRadius, shoulder: shoulder)
                .stroke(
                    isActionState ? Color.ap.accentDefault.opacity(0.6) : Color.ap.stroke,
                    lineWidth: 0.5
                )

            // Content — clipped to the exact same shape so it can never
            // spill outside the curve while transitioning.
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
            .clipShape(NotchShape(bottomRadius: bottomRadius, shoulder: shoulder))
        }
        .frame(width: silhouetteWidth, height: silhouetteHeight)
        .contentShape(NotchShape(bottomRadius: bottomRadius, shoulder: shoulder))
        // NOTE: no `.onTapGesture` / `.onHover` — hover detection happens
        // at the NSEvent level in `NotchPanel`. See its comments for why.
        //
        // No drop shadow: on the transparent overlay window a large soft
        // shadow pooled a visible dark halo around the silhouette on the
        // desktop, so the panel sits flush instead.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(transitionAnimation, value: displayState)
        .animation(.smooth(duration: 0.28), value: agentManager.activeSessions.count)
        .animation(.smooth(duration: 0.28), value: agentManager.pendingPermissions.count)
    }

    /// Body fill for the silhouette. Compact / dormant pill is pure black;
    /// expanded card gets the design's subtle vertical gradient.
    private var silhouetteFill: AnyShapeStyle {
        if isExpanded {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color.ap.bgCardTop, Color.ap.bgCardBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        return AnyShapeStyle(Color.ap.bgPill)
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
        let waiting = waitingSessionCount(sessions)
        let primary = sortedSessions.first
        let summary = pillSummary(sessions: sessions, waiting: waiting)

        HStack(spacing: 8) {
            // Centered content — Spacers on both sides distribute slack
            // equally instead of pinning the chevron to the far right
            // edge, which made the pill look left-heavy.
            Spacer(minLength: 0)

            // Chrome pixel dino. pixelSize 0.75 = ~16pt tall, ~57% of
            // the visible notch interior. pixelSize 1 (21pt, 75%) looked
            // vertically maxed-out per user feedback. Sub-1 pixelSize
            // means ~1.5 device pixels per sprite pixel on Retina —
            // slight edge antialias, but a chunky pixel-art silhouette
            // tolerates it without visible blur.
            if let primary {
                DinoView(
                    species: .rex,
                    state: DinoState.from(primary),
                    pixelSize: 0.75
                )
            } else {
                Circle()
                    .fill(Color.white.opacity(0.4))
                    .frame(width: 6, height: 6)
            }

            // Status text — color matches the dominant state
            Text(summary.text)
                .font(.system(size: 11.5, weight: .medium))
                .tracking(-0.1)
                .monospacedDigit()
                .foregroundStyle(summary.color)

            // Waiting indicator — pulsing dot only when something needs us
            if waiting > 0 {
                // Faster pulse on the pill (1.2s) — design uses this on
                // the urgent waiting indicator to push for action.
                PulsingDot(color: .ap.statusWaiting, size: 6, duration: 1.2)
            }

            // Chevron hint: ⌄ collapsed → ⌃ expanded.
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))

            Spacer(minLength: 0)
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .frame(maxHeight: .infinity)
    }

    /// `(text, color)` for the compact pill's status line. Colour tracks
    /// the most-urgent state; text always surfaces the total session
    /// count so a glance answers BOTH "is anything urgent?" and "how
    /// many agents am I juggling?".
    ///
    /// Examples:
    /// - 0 sessions             → "no agents"
    /// - All 5 working          → "5 working"           (no ratio when same state)
    /// - 1 waiting, 4 working   → "1 of 5 waiting"
    /// - 3 working of 5         → "3 of 5 working"
    /// - All 5 truly done       → "all done"
    /// - 5 idle (waitingForInput) → "5 idle"
    private func pillSummary(sessions: [AgentSession], waiting: Int) -> (text: String, color: Color) {
        let total = sessions.count
        if total == 0 {
            return ("no agents", .white.opacity(0.5))
        }
        let errors = sessions.filter { $0.status == .stopped }.count
        let working = sessions.filter { $0.status == .active }.count
        let trulyDone = sessions.filter { $0.status == .done }.count

        // Helper: "N of M state" when N < M, "M state" when N == M.
        func phrase(_ count: Int, _ word: String) -> String {
            count == total ? "\(total) \(word)" : "\(count) of \(total) \(word)"
        }

        if waiting > 0 {
            return (phrase(waiting, "waiting"), .ap.textOrange)
        }
        if errors > 0 {
            return (phrase(errors, "error"), .ap.textRed)
        }
        if working > 0 {
            return (phrase(working, "working"), .ap.textTeal)
        }
        // Reserve "all done" for sessions truly in .done state. Most
        // post-turn sessions sit in .waitingForInput (agent finished its
        // turn, awaiting the next user message) — those are "idle", not
        // "done", and calling them done would imply the session ended.
        if trulyDone == total {
            return (total == 1 ? "1 done" : "all done", .ap.statusDone)
        }
        // 0.75 white reads as "muted but legible" on the black notch;
        // anything lower (0.55, the previous value) blends into the
        // background and forces the user to lean in.
        return (total == 1 ? "1 idle" : "\(total) idle", .white.opacity(0.75))
    }

    /// Sessions that need the user RIGHT NOW (permission + question).
    private func waitingSessionCount(_ sessions: [AgentSession]) -> Int {
        sessions.filter { $0.pendingPermission != nil || $0.pendingQuestion != nil }.count
    }

    // MARK: - Expanded (cards)

    @State private var allowAllResetTask: Task<Void, Never>?
    @State private var denyAllResetTask: Task<Void, Never>?
    @State private var toastMessage: String?
    @State private var toastGeneration: Int = 0

    @ViewBuilder
    private var expandedView: some View {
        let sessions = sortedSessions
        // Only count permissions that actually have a visible banner in a
        // session card. The pendingPermissions array can have stale entries
        // (e.g., terminal approval cleared session.pendingPermission but the
        // array entry wasn't removed in the same cycle). Using the array
        // directly would show "Allow All (2)" with zero visible banners.
        let permissions = agentManager.pendingPermissions.filter { req in
            agentManager.sessions[req.sessionId]?.pendingPermission?.id == req.id
        }

        // Reserve room for the notch silhouette at the top so the first card
        // doesn't get cropped by the curve.
        let topInset: CGFloat = hasNotch ? panelState.notchHeight + 4 : 8

        VStack(spacing: 0) {
            // Top space to clear the notch silhouette overhang.
            Color.clear.frame(height: topInset)

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
            } else {
            // ScrollView so >5 cards stay reachable instead of being clipped
            // by the silhouette's max height.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    // Bulk actions at the top when 2+ permissions are queued
                    // across multiple sessions. The per-session banner is
                    // rendered inside each SessionCard so each request lives
                    // visually attached to the project that triggered it.
                    if permissions.count >= 2 {
                        HStack(spacing: 8) {
                            Button {
                                if agentManager.allowAllConfirm {
                                    for req in permissions { agentManager.approvePermission(id: req.id) }
                                    agentManager.allowAllConfirm = false
                                } else {
                                    withAnimation(.easeInOut(duration: 0.15)) { agentManager.allowAllConfirm = true; agentManager.denyAllConfirm = false }
                                    allowAllResetTask?.cancel()
                                    allowAllResetTask = Task { try? await Task.sleep(for: .seconds(5)); withAnimation { agentManager.allowAllConfirm = false } }
                                }
                            } label: {
                                Label(
                                    agentManager.allowAllConfirm ? "Confirm Allow All?" : "Allow All (\(permissions.count))",
                                    systemImage: "checkmark.circle"
                                )
                                .font(.system(size: 11, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(.white.opacity(agentManager.allowAllConfirm ? 0.18 : 0.1))
                                .foregroundStyle(.green)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)

                            Button {
                                if agentManager.denyAllConfirm {
                                    for req in permissions { agentManager.denyPermission(id: req.id) }
                                    agentManager.denyAllConfirm = false
                                } else {
                                    withAnimation(.easeInOut(duration: 0.15)) { agentManager.denyAllConfirm = true; agentManager.allowAllConfirm = false }
                                    denyAllResetTask?.cancel()
                                    denyAllResetTask = Task { try? await Task.sleep(for: .seconds(5)); withAnimation { agentManager.denyAllConfirm = false } }
                                }
                            } label: {
                                Label(
                                    agentManager.denyAllConfirm ? "Confirm Deny All?" : "Deny All",
                                    systemImage: "xmark.circle"
                                )
                                .font(.system(size: 11, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(.white.opacity(agentManager.denyAllConfirm ? 0.14 : 0.08))
                                .foregroundStyle(.red.opacity(0.8))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Session cards. Each card renders its own pending
                    // permission banner inline so the user sees the request
                    // attached to the project it came from (sortedSessions
                    // already puts `waitingForPermission` at the top).
                    ForEach(sessions, id: \.id) { session in
                        SessionCard(session: session, agentManager: agentManager) { msg in
                            showToast(msg)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 12)
            }
            .frame(width: 380)
            .frame(maxHeight: .infinity)
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
            // Toast MUST be after .mask — otherwise the gradient fades it
            // to invisible right at the bottom where it appears.
            .overlay(alignment: .bottom) {
                if let toast = toastMessage {
                    Text(toast)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.blue.opacity(0.45)))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 28)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: toastMessage)
            }   // closes `else` (populated branch)

            // Footer — session count + keyboard hint + Settings. Stays
            // anchored to the bottom of the silhouette regardless of count.
            panelFooter(sessionCount: sessions.count)
        }   // closes outer VStack(spacing: 0)
    }

    // MARK: - Panel header / footer

    @ViewBuilder
    private func panelFooter(sessionCount: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(sessionCount) " + (sessionCount == 1 ? "session" : "sessions"))
                .foregroundStyle(Color.ap.fgDim)
                .monospacedDigit()

            Spacer(minLength: 4)

            Text("⌥⌘P")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.7))
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
            Text("toggle")
                .foregroundStyle(Color.ap.fgDim)

            // Real button (the old footer was a non-interactive label, so it
            // looked clickable but did nothing). SettingsLink is the supported
            // way to open the Settings scene from an accessory app.
            SettingsLink {
                HStack(spacing: 3) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Settings")
                }
                .foregroundStyle(Color.ap.fgDim)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 10))
        .padding(.horizontal, 12)
        .padding(.top, 7)
        .padding(.bottom, 7)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.ap.divider)
                .frame(height: 0.5)
        }
    }

    // MARK: - Toast

    private func showToast(_ message: String) {
        toastGeneration += 1
        let gen = toastGeneration
        toastMessage = message
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if toastGeneration == gen { toastMessage = nil }
        }
    }

    // MARK: - Helpers

    private var sortedSessions: [AgentSession] {
        agentManager.activeSessions.sorted { a, b in
            let pa = sortPriority(a)
            let pb = sortPriority(b)
            // Tie-break by recency so cold-started sessions (all sharing
            // `.waitingForInput`) order by transcript mtime instead of
            // landing in arbitrary order — Swift's `sorted(by:)` is not
            // stable, so without this `primary = first` was picking
            // whichever session the sort happened to land on.
            if pa != pb { return pa < pb }
            return a.lastEventTime > b.lastEventTime
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

}

// MARK: - Session Card

struct SessionCard: View {
    let session: AgentSession
    let agentManager: AgentManager
    var onToast: (String) -> Void = { _ in }
    @State private var hovering = false
    @State private var jumpHovering = false
    // branch + usage live on AgentSession itself, populated by
    // SessionMetadataService while the panel is expanded. The card just
    // reads them — no per-view Tasks, no per-card I/O.

    private var badge: StatusBadge { StatusBadge.from(session) }
    private var isWaiting: Bool { badge == .waiting }

    /// True when an inline action banner (permission or question) is showing.
    /// Suppresses Row 4's meta line so the banner gets visual focus.
    private var hasInlineBanner: Bool {
        session.pendingPermission != nil || session.pendingQuestion != nil
    }

    /// Filepath shown between row2 (prompt) and row4 (meta). Sourced
    /// from a pending permission first (the file the agent is asking
    /// about right now), falling back to the most recent file-touching
    /// tool. nil if neither applies — Bash permissions for non-file
    /// commands like `curl` correctly omit this row.
    private var displayFilePath: String? {
        if let path = session.pendingPermission?.filePath, !path.isEmpty {
            return path
        }
        if let path = session.currentToolCall?.toolInput["file_path"]?.stringValue, !path.isEmpty {
            return path
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row1
            row2Body
            if let path = displayFilePath { row3FilePath(path) }
            if !hasInlineBanner { row4Meta }

            // Inline interaction card. Permission has priority over question
            // (a single session never legitimately has both, but a race
            // could; prioritize unblocking the bridge first).
            //
            // The Group + outer `.id()` is load-bearing: without it,
            // SwiftUI preserves the @State reply text AND can render
            // stale content when one permission immediately follows
            // another on the same session (e.g. user clicks Allow on
            // request A, then request B arrives — the banner can show
            // A's tool input despite session.pendingPermission being B).
            // Tying the wrapping Group's identity to the current pending
            // permission id forces SwiftUI to tear down + rebuild the
            // entire subtree whenever the permission changes, resetting
            // @State and re-reading toolInput from the new request.
            Group {
                if let req = session.pendingPermission {
                    PermissionBanner(
                        request: req,
                        queuePosition: 1, queueTotal: 1,
                        strategy: session.agentKind.permissionStrategy,
                        onAllow: { agentManager.approvePermission(id: req.id) },
                        onAlwaysAllow: {
                            // Dispatch through the agent's native rule writer.
                            // `.notSupported` strategies hide the Always button
                            // in the banner, so this branch shouldn't fire for
                            // them — but if it somehow does, fall through to a
                            // plain Allow without persistence.
                            if case .native(let writer) = session.agentKind.permissionStrategy {
                                let input = req.toolInput.mapValues { $0.value }
                                do {
                                    try writer.writeAllowRule(toolName: req.toolName, toolInput: input, cwd: req.cwd)
                                    onToast("Always allow saved")
                                } catch {
                                    onToast("Couldn't save rule: \(error.localizedDescription)")
                                }
                            }
                            agentManager.approvePermission(id: req.id)
                        },
                        onDeny: { reason in
                            // Pass nil through when reply is empty — denyPermission
                            // wraps with ClaudeCodeMessages.formattedRejection so
                            // nil becomes the no-reason REJECT_MESSAGE and a real
                            // reply becomes REJECT_MESSAGE_WITH_REASON_PREFIX + text.
                            agentManager.denyPermission(id: req.id, reason: reason)
                        },
                        onJump: { TerminalJumper.jump(to: session) }
                    )
                }
            }
            .id(session.pendingPermission?.id ?? "no-pending")

            if let question = session.pendingQuestion, session.pendingPermission == nil {
                QuestionBanner(
                    question: question,
                    agentDisplayName: session.agentKind.displayName,
                    onJump: { TerminalJumper.jump(to: session) }
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .overlay(cardBorder)
        // Subtle warm-orange glow on waiting cards so the eye snaps to
        // them in a stack of 5+ cards.
        .shadow(
            color: isWaiting ? Color.ap.statusWaiting.opacity(0.08) : .clear,
            radius: isWaiting ? 14 : 0,
            x: 0, y: isWaiting ? 4 : 0
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .animation(.easeOut(duration: 0.18), value: isWaiting)
    }

    // MARK: - Row 1: agent tile + repo · branch + host badge + status

    @ViewBuilder
    private var row1: some View {
        HStack(spacing: 8) {
            AgentMonogramTile(agent: session.agentKind)

            // Repo + branch (when the cwd is a git repo). projectName is
            // the cwd basename; branch comes from `git symbolic-ref` and
            // is omitted gracefully when the cwd isn't a git repo or is
            // in detached-HEAD state.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(session.projectName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .tracking(-0.1)
                    .foregroundStyle(Color.ap.fg)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(2)
                if let branch = session.branch, !branch.isEmpty {
                    Text(branch)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color.ap.fgDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                }
            }

            Spacer(minLength: 6)

            // Host badge — only when we actually detected which terminal
            // / editor app launched the agent (via libproc parent chain).
            // Shown when nil rather than inferring would lie about data
            // we don't have.
            HStack(spacing: 6) {
                if let host = session.host {
                    HostBadge(host: host)
                }
                if badge.shouldPulse {
                    // Sessions card working dot: 1.6s — calm and steady.
                    PulsingDot(color: badge.dotColor, size: 6, duration: 1.6)
                } else {
                    Circle()
                        .fill(badge.dotColor)
                        .frame(width: 6, height: 6)
                }
                Text(badge.label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(badge.color)
                    .fixedSize()
            }
        }
    }

    // MARK: - Row 2: prompt + current action
    //
    // Two-row body: the user's most recent prompt up top (so context is
    // always visible) and a "what's happening right now" line below it.
    // The action line picks the most informative signal available:
    //   1. A tool whose `PreToolUse` fired but hasn't completed → show the
    //      tool, monospaced, with a pulsing dot. Agent is mid-turn.
    //   2. Otherwise, the latest assistant reply (extracted from the
    //      transcript by `TranscriptReader`). Updates near-real-time via
    //      `TranscriptWatcher` — Claude Code writes one JSONL line per
    //      completed turn, so we can't stream tokens but we DO see every
    //      message as it lands.
    //   3. If neither prompt nor action exists → "Idle".

    private enum ActionLine {
        case tool(ToolCall)
        case assistantReply(String)
    }

    private var trimmedPrompt: String? {
        guard let raw = session.lastUserPrompt else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What to surface on the second line.
    ///
    /// `currentToolCall` is non-nil from the first `toolStarted` until the
    /// reducer's `.stopped` event clears it at turn end. We surface it
    /// throughout that entire window — including the `.succeeded` /
    /// `.failed` gap between tools in a multi-tool turn — because falling
    /// back to `lastAssistantMessage` there would briefly flash the
    /// PREVIOUS turn's reply text (the new reply hasn't been written to
    /// the transcript yet). Showing "Edit: foo.swift ✓" until the next
    /// tool's `PreToolUse` fires is the right visual continuity.
    ///
    /// **Suppressed when a permission banner is showing**: the banner
    /// already renders the same command verbatim in its code block, and
    /// the running-dot animation here was misleading — the tool isn't
    /// actually running, it's waiting for the user's click.
    private var activeAction: ActionLine? {
        if session.pendingPermission != nil { return nil }
        if let tool = session.currentToolCall {
            return .tool(tool)
        }
        if let reply = session.lastAssistantMessage, !reply.isEmpty {
            return .assistantReply(reply)
        }
        return nil
    }

    @ViewBuilder
    private var row2Body: some View {
        let prompt = trimmedPrompt
        let action = activeAction

        if prompt == nil && action == nil {
            Text("Idle — no recent activity")
                .font(.system(size: 12))
                .foregroundStyle(Color.ap.fgFaint)
                .italic()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if let prompt {
                    Text(prompt)
                        .font(.system(size: 12))
                        .lineSpacing(4)
                        .foregroundStyle(Color.ap.fgMuted)
                        .lineLimit(action == nil ? 2 : 1)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let action {
                    actionLineView(action)
                }
            }
        }
    }

    /// File-path row between row2 and row4. Monospaced, dimmed —
    /// "what file is currently the subject of this card". For a
    /// pending permission this is the file the agent wants to touch;
    /// for an active session it's the last file the tool worked on.
    @ViewBuilder
    private func row3FilePath(_ path: String) -> some View {
        HStack(spacing: 8) {
            Text(path)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.42))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            // Diff stats (+N / -N) slot reserved — we don't track line
            // counts yet. When we do, render here.
        }
    }

    /// Visual indicator for the tool action line. Running = pulsing blue
    /// (live work); succeeded = solid green; failed = solid red. Static
    /// dots in terminal states keep the card calm — only ONE pulsing
    /// thing on screen at a time (the live tool, or none).
    @ViewBuilder
    private func toolStatusIndicator(_ status: ToolCall.Status) -> some View {
        switch status {
        case .running:
            PulsingDot(color: .ap.statusWorking, size: 5, duration: 1.4)
        case .succeeded:
            Circle().fill(Color.ap.statusDone).frame(width: 5, height: 5)
        case .failed:
            Circle().fill(Color.ap.statusError).frame(width: 5, height: 5)
        }
    }

    @ViewBuilder
    private func actionLineView(_ action: ActionLine) -> some View {
        switch action {
        case .tool(let tool):
            HStack(spacing: 6) {
                toolStatusIndicator(tool.status)
                Text(tool.displayDescription)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.ap.fgDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .assistantReply(let text):
            // Lower-contrast (fgDim) than the prompt above (fgMuted) so the
            // two lines read as "user said X, agent said Y" at a glance.
            Text(text)
                .font(.system(size: 12))
                .lineSpacing(4)
                .foregroundStyle(Color.ap.fgDim)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Row 4: meta (elapsed · tokens · cost · jump)

    @ViewBuilder
    private var row4Meta: some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                Image(systemName: "clock")
                    .font(.system(size: 9))
                Text(elapsedText)
            }
            .foregroundStyle(Color.ap.fgFaint)

            if let tokenText = formattedTokens() {
                Text(tokenText)
                    .foregroundStyle(Color.ap.fgFaint)
            }
            if let costText = formattedCost() {
                Text(costText)
                    .foregroundStyle(Color.ap.fgFaint)
            }

            Spacer(minLength: 4)

            Button(action: { TerminalJumper.jump(to: session) }) {
                HStack(spacing: 3) {
                    Text("Jump to terminal")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(jumpHovering ? Color.white : Color.ap.fgFaint)
            }
            .buttonStyle(.plain)
            .onHover { jumpHovering = $0 }
            .help("Bring the terminal running this agent to the front")
        }
        .font(.system(size: 10))
        .monospacedDigit()
        .animation(.easeOut(duration: 0.12), value: jumpHovering)
    }

    /// Scales the cumulative token count into a compact human-readable
    /// form. Visibility only conditions on `session.usage` being present —
    /// formatting alone handles scale, so the value appears once the
    /// first poll returns and never flickers in/out as count grows.
    ///
    /// - <1k     → "84 tok"
    /// - 1k..1M  → "84.2k tok"
    /// - 1M..1B  → "356.6M tok"
    /// - ≥1B     → "2.1B tok"
    private func formattedTokens() -> String? {
        guard let usage = session.usage else { return nil }
        let n = Double(usage.totalTokens)
        if n >= 1_000_000_000 { return String(format: "%.1fB tok", n / 1_000_000_000) }
        if n >= 1_000_000     { return String(format: "%.1fM tok", n / 1_000_000) }
        if n >= 1_000         { return String(format: "%.1fk tok", n / 1_000) }
        return "\(usage.totalTokens) tok"
    }

    /// "$0.42" / "<$0.01" / "$12.34". Hidden when the model is unknown
    /// (cost would be wrong) or cost is exactly zero (no work done yet).
    /// Any non-zero cost — even fractions of a cent — shows as `<$0.01`
    /// so the user gets feedback the moment billing starts.
    private func formattedCost() -> String? {
        guard let cost = session.usage?.estimatedCostUSD, cost > 0 else { return nil }
        if cost < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", cost)
    }

    // MARK: - Background / border

    @ViewBuilder
    private var cardBackground: some View {
        let fill: Color = {
            if isWaiting { return Color.ap.rowBgWaiting }
            return hovering
                ? Color.white.opacity(0.09)
                : Color.ap.rowBg
        }()
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(fill)
    }

    @ViewBuilder
    private var cardBorder: some View {
        // Spec waiting row boxShadow includes an INNER 0.5px stroke at
        // rgba(255,159,10,.25) that sits *inside* the primary orange
        // border. SwiftUI doesn't have a CSS-style inset shadow, so we
        // approximate it with a second RoundedRectangle stroke inset by
        // 0.5pt from the primary border.
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isWaiting ? Color.ap.rowStrokeWaiting : Color.ap.strokeStrong,
                    lineWidth: isWaiting ? 1.0 : 0.5
                )
            if isWaiting {
                RoundedRectangle(cornerRadius: 9.5, style: .continuous)
                    .inset(by: 0.5)
                    .stroke(
                        Color.ap.statusWaiting.opacity(0.25),
                        lineWidth: 0.5
                    )
            }
        }
    }
}

// MARK: - Activity Feed

struct ActivityFeedView: View {
    let tools: [ToolCall]

    var body: some View {
        // TimelineView ticks every second so running tool durations update live.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 2) {
                ForEach(tools) { tool in
                    ActivityRow(tool: tool, tick: context.date)
                }
            }
        }
    }
}

struct ActivityRow: View {
    let tool: ToolCall
    let tick: Date  // from TimelineView for live elapsed updates

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
            Text(toolDuration(tick: tick))
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.3))
            statusIcon
        }
    }

    private func toolDuration(tick: Date) -> String {
        guard let end = tool.endTime else {
            let seconds = max(0, Int(tick.timeIntervalSince(tool.startTime)))
            return seconds < 1 ? "<1s" : "\(seconds)s"
        }
        let ms = max(0, Int(end.timeIntervalSince(tool.startTime) * 1000))
        if ms < 100 { return "instant" }
        if ms < 1000 { return "\(ms)ms" }
        return "\(ms / 1000)s"
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
