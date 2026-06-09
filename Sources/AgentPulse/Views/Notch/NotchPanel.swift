import AgentPulseCore
import AppKit
import SwiftUI

enum NotchDisplayState: Equatable {
    case dormant, compact, expanded
}

/// Wrapper passed to NSMenuItem.representedObject so the AgentPulsePanel
/// click target can find its way back to the live NotchPanel instance and
/// the chosen display name.
final class NotchPanelMenuPick: NSObject {
    weak var panel: NotchPanel?
    let name: String?
    init(panel: NotchPanel, name: String?) {
        self.panel = panel
        self.name = name
    }
}

/// NSPanel subclass that accepts key/main status — required so non-activating
/// borderless panels still deliver mouse events to SwiftUI hit-testing.
final class AgentPulsePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    @objc func menuPickDisplay(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? NotchPanelMenuPick else { return }
        pick.panel?.applyDisplayPreference(pick.name)
    }

    @objc func menuPickAutoDisplay(_ sender: NSMenuItem) {
        guard let panel = sender.representedObject as? NotchPanel else { return }
        panel.applyDisplayPreference(nil)
    }

    @objc func menuUninstallHooks(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Uninstall AgentPulse hooks?"
        alert.informativeText = """
            This removes all AgentPulse hooks from ~/.claude/settings.json. \
            The app will quit after uninstalling.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall & Quit")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try HookInstaller().uninstall()
            UserDefaults.standard.removeObject(forKey: "hookConsentGiven")
            // Clean up launch token
            let tokenURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".agentpulse/.launch-token")
            try? FileManager.default.removeItem(at: tokenURL)
        } catch {
            let errAlert = NSAlert()
            errAlert.messageText = "Uninstall failed"
            errAlert.informativeText = error.localizedDescription
            errAlert.runModal()
            return
        }
        NSApp.terminate(nil)
    }
}

// (No NSHostingView subclass needed — click-through is handled at the panel
// level via NSEvent mouse monitors that toggle `ignoresMouseEvents`.)

@MainActor
@Observable
final class NotchPanelState {
    var displayState: NotchDisplayState = .dormant
    var hasNotch = false
    var notchHeight: CGFloat = 24
    var notchWidth: CGFloat = 220

    var isExpanded: Bool { displayState == .expanded }
    var isVisible: Bool { displayState != .dormant }
}

/// Manages the floating notch overlay window.
///
/// Architecture (DynamicNotchKit-style):
/// - The NSPanel is sized **once** to half the screen and never resized.
/// - All visual transitions live inside SwiftUI; the OS window stays put,
///   eliminating the jank caused by `setFrame(animate: false)`.
/// - The panel's contentView is fully transparent; the visible silhouette
///   is drawn by a `NotchShape` mask over a black rectangle inside SwiftUI.
@MainActor
final class NotchPanel {
    private var panel: NSPanel?
    private let agentManager: AgentManager
    let panelState = NotchPanelState()
    private var hoverTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var dormantTask: Task<Void, Never>?
    private var screenObserver: Any?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalRightClickMonitor: Any?
    private var localRightClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var lastMouseInSilhouette: Bool = false

    init(agentManager: AgentManager) {
        self.agentManager = agentManager
    }

    // No deinit — @MainActor properties can't be accessed from nonisolated
    // deinit. Instead, setup() guards against double-install and teardown()
    // must be called explicitly before the object is released.

    func teardown() {
        if let obs = screenObserver {
            NotificationCenter.default.removeObserver(obs)
            screenObserver = nil
        }
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m); localMouseMonitor = nil }
        if let m = globalRightClickMonitor { NSEvent.removeMonitor(m); globalRightClickMonitor = nil }
        if let m = localRightClickMonitor { NSEvent.removeMonitor(m); localRightClickMonitor = nil }
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        cancelAllTasks()
    }

    // MARK: - Debug Inspection

    var debugIsPanelVisible: Bool { panel?.isVisible ?? false }
    var debugPanelFrame: CGRect { panel?.frame ?? .zero }
    var debugPanelScreen: String { panel?.screen?.localizedName ?? "none" }

    func debugIsMouseInsideSilhouette(x: Double, y: Double) -> Bool {
        isMouseInsideSilhouette(mouseScreenPoint: NSPoint(x: x, y: y))
    }

    // MARK: - Setup

    func setup() {
        // Guard against double-install — calling setup() twice without
        // teardown() would orphan the old monitors.
        if panel != nil { teardown() }

        refreshScreenInfo()
        createPanel()
        installContent()
        observeScreenChanges()
        installMouseMonitors()

        // Place the panel on whichever screen the cursor is on right now.
        if DisplayPreference.preferredName == nil {
            let mouse = NSEvent.mouseLocation
            if let s = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
                movePanelToScreen(s)
            }
        }
    }

    // MARK: - State Transitions
    //
    // No `setFrame` calls here — the panel is fixed-size. We only mutate
    // `panelState.displayState`; SwiftUI animates the rest.

    func transitionToDormant() {
        cancelAllTasks()
        lastMouseInSilhouette = false
        panel?.ignoresMouseEvents = true
        panelState.displayState = .dormant
        // No expanded panel = no need to keep polling transcripts.
        agentManager.metadataService.stop()
        // Wait for the SwiftUI shrink animation to finish before fading the
        // OS window out, otherwise we'd see a sudden disappear.
        dormantTask = Task {
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled else { return }
            await fadeOutPanel()
        }
    }

    func transitionToCompact() {
        cancelAllTasks()
        ensurePanelVisible()
        panelState.displayState = .compact
        // Compact pill shows only summary text — no per-card data needed.
        agentManager.metadataService.stop()
    }

    func transitionToExpanded() {
        cancelAllTasks()
        ensurePanelVisible()
        panelState.displayState = .expanded
        // Cards are now visible — kick off the branch + usage polling.
        agentManager.metadataService.start(agentManager: agentManager)
        makeKeyIfPermissions()
    }

    /// Make the panel key window so keyboard shortcuts work. Safe to call
    /// anytime — no-ops if no permissions or panel is nil.
    func makeKeyIfPermissions() {
        if !agentManager.pendingPermissions.isEmpty {
            panel?.makeKey()
        }
    }

    func hide() {
        cancelAllTasks()
        panelState.displayState = .dormant
        panel?.orderOut(nil)
    }

    func scheduleCollapse(delay: TimeInterval = 0.15) {
        collapseTask?.cancel()
        collapseTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            transitionToCompact()
        }
    }

    func scheduleDormant(delay: TimeInterval = 5) {
        dormantTask?.cancel()
        dormantTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            transitionToDormant()
        }
    }

    // MARK: - Panel Creation

    /// Maximum content size — derived from SilhouetteSizing so the panel
    /// window is always large enough to hold the biggest silhouette plus
    /// shadow room. Anything outside the visible silhouette is click-through.
    ///
    /// Width buffer is tuned to *just* fit the shadow (radius 18 each side):
    /// `expandedWidth + 36` gives ~18pt of clear space on each side. The old
    /// `+ 80` value left 40pt gaps that revealed background windows ("bleed-
    /// through") next to the cards — visually distracting and ugly.
    private static let panelMaxSize = NSSize(
        width: SilhouetteSizing.expandedWidth + 36,   // 410 + ~18pt each side for shadow
        height: SilhouetteSizing.expandedMaxHeight + 40
    )

    private func createPanel() {
        let screen = currentScreen()


        // Fixed-size panel: never resized at the OS level, so SwiftUI animates
        // the visible silhouette inside it without window jank.
        let size = Self.panelMaxSize
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height
        )
        let initRect = NSRect(origin: origin, size: size)

        let p = AgentPulsePanel(
            contentRect: initRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        p.hasShadow = false
        p.backgroundColor = .clear
        p.isOpaque = false
        // .popUpMenu (101) draws above the menu bar (.statusBar = 25) but
        // well below the cursor level (~kCGCursorWindowLevel ≈ 2147483630).
        // .screenSaver (1000) was masking the cursor sprite for some users.
        p.level = .popUpMenu
        p.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        // Default: ignore all mouse events. The global mouse monitor below
        // flips this to `false` only while the cursor is inside the visible
        // notch silhouette — guaranteeing 100% click-through everywhere else.
        p.ignoresMouseEvents = true
        self.panel = p
    }

    private func installContent() {
        guard let panel else { return }
        let view = NotchContentView(
            agentManager: agentManager,
            panelState: panelState
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
    }

    /// The current "interactive" rect inside the panel (panel-local coords,
    /// bottom-left origin). Anything outside this is click-through.
    ///
    /// **Critical**: this MUST come from the same `SilhouetteSizing` source
    /// as `NotchContentView.silhouetteSize`. If they drift, the hot zone
    /// extends past the visible black region and the user perceives a huge
    /// invisible "trap" hovering over their workspace.
    private func currentHitTestRect() -> CGRect {
        guard let panel else { return .zero }
        if panelState.displayState == .dormant { return .zero }

        let size = SilhouetteSizing.size(
            state: panelState.displayState,
            hasNotch: panelState.hasNotch,
            notchWidth: panelState.notchWidth,
            notchHeight: panelState.notchHeight,
            sessionCount: agentManager.activeSessions.count,
            permissionCount: agentManager.pendingPermissions.count
        )
        // NotchShape extends `shoulder` pixels past the body on each side
        // (the concave curves into the menu bar). Include that overhang
        // in the interactive rect — otherwise the visible shoulders are
        // click-through and hovering onto them collapses the panel.
        let shoulder = SilhouetteSizing.shoulder(state: panelState.displayState, hasNotch: panelState.hasNotch)
        let fullWidth = size.width + 2 * shoulder

        let bounds = CGRect(origin: .zero, size: panel.frame.size)
        let clampedW = min(fullWidth, bounds.width)
        let clampedH = min(size.height, bounds.height)
        let originX = max(0, (bounds.width - clampedW) / 2)
        // Panel coords are bottom-left origin → "top of the panel" = maxY.
        let originY = max(0, bounds.height - clampedH)
        return CGRect(x: originX, y: originY, width: clampedW, height: clampedH)
    }

    private func ensurePanelVisible() {
        guard let panel else { return }
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            // Fade in to hide first-frame layout glitches.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
    }

    private func fadeOutPanel() async {
        guard let panel else { return }
        // NSAnimationContext's completionHandler fires on an arbitrary queue.
        // Use Task { @MainActor in } (not DispatchQueue.main.async) so the
        // closure is formally MainActor-isolated under strict concurrency.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            } completionHandler: {
                Task { @MainActor in
                    panel.orderOut(nil)
                    panel.alphaValue = 1
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Screen

    /// Choose which physical display to render the notch panel on.
    ///
    /// Order of preference:
    /// 1. **The user's pinned display** (set via right-click menu) — wins
    ///    over auto-detection because the user told us explicitly.
    /// 2. **A real notch screen** (`hasNotch == true`) — the obvious target.
    /// 3. **The screen containing the system menu bar** — `NSScreen.screens[0]`
    ///    is conventionally the primary display where the user is looking.
    /// 4. **`NSScreen.main`** — fallback for unusual setups.
    /// 5. **First screen at all** — last resort, never `nil` because at least
    ///    one display is always present while the app is running.
    ///
    /// Why this matters: on a notch MacBook running in "Larger Text" scaled
    /// mode, `safeAreaInsets.top` reports 0 and `hasNotch` lies. Without a
    /// fallback to the primary display, the panel jumps to whichever screen
    /// happened to be `NSScreen.main` at startup — typically a connected
    /// external monitor — and the user can't find it.
    private func currentScreen() -> NSScreen {
        if let pinned = DisplayPreference.resolveScreen() {
            return pinned
        }
        if let notch = NSScreen.screens.first(where: { $0.hasNotch }) {
            return notch
        }
        // screens.first covers all real scenarios. This return is unreachable
        // for a running GUI app but satisfies the compiler.
        return NSScreen.screens.first ?? NSScreen.main!
    }

    private func refreshScreenInfo() {
        let screen = currentScreen()
        panelState.hasNotch = screen.hasNotch
        panelState.notchHeight = screen.notchSize.height
        panelState.notchWidth = screen.notchSize.width
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshScreenInfo()
                self.repositionPanel()
            }
        }
    }

    // MARK: - Mouse Monitoring
    //
    // Strategy borrowed from open-vibe-island. The panel is mouse-disabled by
    // default; we use NSEvent global+local mouse monitors to track cursor
    // position in screen space and re-enable mouse events ONLY when the
    // cursor is inside the visible silhouette. Outside the silhouette, the
    // panel is fully click-through and the user's other apps work normally.

    private func installMouseMonitors() {
        // Global monitor: fires for cursor movement *outside* our process.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor in self?.updateMouseState() }
        }
        // Right-click monitors for the display-picker context menu.
        globalRightClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            Task { @MainActor in self?.handleRightClick(at: NSEvent.mouseLocation) }
        }
        localRightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            Task { @MainActor in self?.handleRightClick(at: NSEvent.mouseLocation) }
            return event
        }
        // Local monitor: fires for cursor movement *over* our own panel.
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            Task { @MainActor in self?.updateMouseState() }
            return event
        }

        // Keyboard shortcuts for permission approval. The panel must be key
        // window to receive these (done via makeKey in transitionToExpanded).
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Local monitor runs on main thread = MainActor. Call directly.
            return self.handleKeyEvent(event) ? nil : event
        }
    }

    /// Handle ^Y (allow), ^N (deny), ^A (always allow) for the first
    /// pending permission. Returns true if the event was consumed.
    /// `^A` writes an "Always" rule via the agent's `permissionStrategy`
    /// then approves — for agents with `.notSupported`, ^A falls back
    /// to a plain Allow.
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard panelState.displayState == .expanded else { return false }
        guard !agentManager.pendingPermissions.isEmpty else { return false }
        guard event.modifierFlags.contains(.control) else { return false }

        let perm = agentManager.pendingPermissions[0]
        switch event.charactersIgnoringModifiers {
        case "y":
            agentManager.approvePermission(id: perm.id)
            return true
        case "n":
            agentManager.denyPermission(id: perm.id)
            return true
        case "a":
            // Find the originating session's agentKind so we know how
            // to persist the rule. Fall back to a plain Allow if the
            // session is missing or the strategy is .notSupported.
            let agentKind = agentManager.sessions[perm.sessionId]?.agentKind
            if case .native(let writer) = agentKind?.permissionStrategy {
                let input = perm.toolInput.mapValues { $0.value }
                try? writer.writeAllowRule(toolName: perm.toolName, toolInput: input, cwd: perm.cwd)
            }
            agentManager.approvePermission(id: perm.id)
            return true
        default:
            return false
        }
    }

    /// Compute whether the cursor is currently inside the visible silhouette
    /// and toggle `ignoresMouseEvents` accordingly. This is the single source
    /// of truth for click-through behavior.
    ///
    /// **Critical**: handleHover is only called on the inside↔outside
    /// transition, not on every mouse-move event. Otherwise the 180 ms expand
    /// timer would be cancelled and re-scheduled on every pixel of motion and
    /// would never fire.
    private func updateMouseState() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation  // screen coords, bottom-left origin

        // 1. Auto-follow: track which screen the cursor is on and move the
        //    panel there after a short debounce. Skipped when the user has
        //    explicitly pinned a display via the right-click menu.
        followCursorIfNeeded(mouse: mouse)

        // 2. Inside-silhouette detection (drives expand/collapse).
        let inside = isMouseInsideSilhouette(mouseScreenPoint: mouse)
        guard inside != lastMouseInSilhouette else { return }
        lastMouseInSilhouette = inside
        panel.ignoresMouseEvents = !inside
        handleHover(inside)
    }

    /// If the cursor lives on a different screen than the panel, move the
    /// panel there immediately. Pinned preference always wins; expanded
    /// state is skipped so we don't yank the panel during a hover.
    private func followCursorIfNeeded(mouse: NSPoint) {
        guard DisplayPreference.preferredName == nil else { return }
        guard panelState.displayState == .compact || panelState.displayState == .dormant else { return }
        guard let panel else { return }
        guard let cursorScreen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) else { return }

        if panel.screen != cursorScreen {
            movePanelToScreen(cursorScreen)
        }
    }

    private func movePanelToScreen(_ screen: NSScreen) {
        guard let panel else { return }
        let size = panel.frame.size
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height
        )
        panel.setFrameOrigin(origin)
        panelState.hasNotch = screen.hasNotch
        panelState.notchHeight = screen.notchSize.height
        panelState.notchWidth = screen.notchSize.width
    }

    /// True iff the mouse cursor is inside the actual *visible* notch
    /// silhouette — using the real bezier path, not its bounding box. Without
    /// this the two top concave corners count as "inside" even though
    /// nothing is drawn there, triggering hover before the user has actually
    /// touched the visible black area.
    private func isMouseInsideSilhouette(mouseScreenPoint: NSPoint) -> Bool {
        guard let panel, panelState.displayState != .dormant else { return false }
        let panelFrame = panel.frame
        let state = panelState.displayState

        let size = SilhouetteSizing.size(
            state: state,
            hasNotch: panelState.hasNotch,
            notchWidth: panelState.notchWidth,
            notchHeight: panelState.notchHeight,
            sessionCount: agentManager.activeSessions.count,
            permissionCount: agentManager.pendingPermissions.count
        )
        let shoulder = SilhouetteSizing.shoulder(state: state, hasNotch: panelState.hasNotch)

        // Silhouette rect in NSScreen coords (bottom-left origin). `silScreenX`
        // remains at the body's left edge so that `localX` matches the
        // NotchShape path's coordinate system, where `local.x = -shoulder`
        // is the left shoulder tip. The rect rejection below expands by
        // `shoulder` on each side to cover the visible overhang.
        let silScreenX = panelFrame.midX - size.width / 2
        let silTopScreenY = panelFrame.maxY            // NSScreen top of panel
        let silBottomScreenY = silTopScreenY - size.height

        // Cheap rect rejection — full width includes the concave shoulder
        // overhang. Without this the visible 8–10pt shoulders are dead
        // zones that pass clicks through to the app underneath.
        guard mouseScreenPoint.x >= silScreenX - shoulder,
              mouseScreenPoint.x <= silScreenX + size.width + shoulder,
              mouseScreenPoint.y >= silBottomScreenY,
              mouseScreenPoint.y <= silTopScreenY else {
            return false
        }

        // Inside the bounding rect → now check the actual NotchShape path.
        // The path uses local coords where the body is `[0, size.width]`
        // and shoulders extend to `-shoulder` / `size.width + shoulder`.
        // We flip y to convert from NSScreen → local.
        let localX = mouseScreenPoint.x - silScreenX
        let localY = silTopScreenY - mouseScreenPoint.y

        let botR = SilhouetteSizing.bottomRadius(state: state, hasNotch: panelState.hasNotch)
        let localRect = CGRect(origin: .zero, size: size)
        let path = NotchShape(bottomRadius: botR, shoulder: shoulder)
            .path(in: localRect)
            .cgPath
        return path.contains(CGPoint(x: localX, y: localY))
    }

    /// Re-anchor the (fixed-size) panel after a screen-parameter change.
    private func repositionPanel() {
        guard let panel else { return }
        let screen = currentScreen()
        let size = panel.frame.size
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height
        )
        panel.setFrameOrigin(origin)
    }

    // MARK: - Hover (fast: 100ms expand, 150ms collapse)

    private func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()
        let state = panelState.displayState
        if hovering {
            if state == .compact {
                hoverTask = Task {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled else { return }
                    transitionToExpanded()
                }
            } else if state == .expanded {
                collapseTask?.cancel()  // re-hover cancels pending collapse
            }
        } else if state == .expanded {
            // Don't collapse while the user is mid-confirm on a destructive
            // action — they need the panel to stay visible.
            if agentManager.allowAllConfirm
                || agentManager.denyAllConfirm { return }
            let delay: TimeInterval = agentManager.hasPendingPermissions ? 0.6 : 0.2
            scheduleCollapse(delay: delay)
        }
    }

    // MARK: - Tap

    private func handleTap() {
        let state = panelState.displayState
        if state == .compact {
            transitionToExpanded()
        } else if state == .expanded {
            transitionToCompact()
        }
    }

    // MARK: - Right-click → Display picker menu

    private func handleRightClick(at screenPoint: NSPoint) {
        // Only react when the right-click happened *inside* the visible
        // silhouette — anywhere else is none of our business.
        guard isMouseInsideSilhouette(mouseScreenPoint: screenPoint) else { return }
        guard let panel else { return }

        let menu = NSMenu(title: "AgentPulse")

        // Header
        let header = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        // "Auto" item
        let auto = NSMenuItem(title: "Auto (detect notch)", action: #selector(AgentPulsePanel.menuPickAutoDisplay(_:)), keyEquivalent: "")
        auto.target = panel
        auto.representedObject = self
        if DisplayPreference.preferredName == nil { auto.state = .on }
        menu.addItem(auto)

        // One item per connected screen
        menu.addItem(.separator())
        for screen in NSScreen.screens {
            let name = screen.localizedName
            let size = "\(Int(screen.frame.width))×\(Int(screen.frame.height))"
            let item = NSMenuItem(
                title: "\(name) — \(size)",
                action: #selector(AgentPulsePanel.menuPickDisplay(_:)),
                keyEquivalent: ""
            )
            item.target = panel
            item.representedObject = NotchPanelMenuPick(panel: self, name: name)
            if DisplayPreference.preferredName == name { item.state = .on }
            menu.addItem(item)
        }

        // Rules-management menu removed in May 2026 redesign. Allow
        // rules now live in each agent's own config file (e.g.
        // `.claude/settings.local.json`) — manage them via the agent's
        // native UI (Claude's `/permissions`, Codex's TUI rules editor,
        // etc.). See docs/permissions.md > "Drop the rules-management menu".

        // Uninstall + Quit
        menu.addItem(.separator())
        let uninstall = NSMenuItem(
            title: "Uninstall Hooks…",
            action: #selector(AgentPulsePanel.menuUninstallHooks(_:)),
            keyEquivalent: ""
        )
        uninstall.target = panel
        menu.addItem(uninstall)

        let quit = NSMenuItem(title: "Quit DinoPing", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        // NSMenu won't pop up for a nonactivating borderless panel unless
        // the app gets focus first. Briefly activating the app makes the menu
        // appear; the panel itself stays where it is.
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: screenPoint, in: nil)
    }

    /// Called from the AgentPulsePanel menu actions to actually swap displays.
    func applyDisplayPreference(_ name: String?) {
        DisplayPreference.set(name)
        refreshScreenInfo()
        repositionPanel()
    }

    // MARK: - Task Cleanup

    private func cancelAllTasks() {
        hoverTask?.cancel()
        collapseTask?.cancel()
        dormantTask?.cancel()
        agentManager.allowAllConfirm = false
        agentManager.denyAllConfirm = false
    }
}
