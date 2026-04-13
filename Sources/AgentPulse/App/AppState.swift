import AgentPulseCore
import SwiftUI
import os

@MainActor
@Observable
final class AppState {
    let agentManager = AgentManager()
    private(set) var notchPanel: NotchPanel?
    private let hookServer = HookHTTPServer()
    private let hookInstaller = HookInstaller()
    private var serverTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var observeTask: Task<Void, Never>?
    private var lastKnownPermCount = 0

    init() {
        startServices()
        Task { @MainActor in
            self.setupNotchUI()
        }
    }

    // MARK: - Services

    private func startServices() {
        print("[AgentPulse] 🚀 Starting services...")

        do {
            try hookInstaller.installClaudeCodeHooks()
        } catch {
            print("[AgentPulse] ❌ Hook install failed: \(error)")
        }

        let manager = agentManager
        let server = hookServer

        serverTask = Task.detached {
            await server.setEventHandler { event in
                if case .permissionRequest = event {
                    Task { @MainActor in
                        SoundManager.shared.play(.permissionNeeded)
                    }
                }
                return await manager.handleEvent(event)
            }

            await server.setApprovalHandler { payload, agentType in
                let toolName = payload.toolName ?? "Unknown"
                let toolInput = payload.toolInput?.mapValues { $0.value } ?? [:]

                // Check "Always Allow" rules first — auto-approve without UI.
                if AllowRules.isAllowed(toolName: toolName, toolInput: toolInput) {
                    return .allow(hookEvent: "PermissionRequest")
                }

                let requestId = payload.toolUseId ?? "perm-\(UUID().uuidString.prefix(8))"
                let req = PermissionRequest(
                    id: requestId, sessionId: payload.sessionId,
                    toolName: toolName,
                    toolInput: payload.toolInput ?? [:],
                    cwd: payload.cwd, receivedAt: .now
                )
                await MainActor.run {
                    manager.getOrCreateSession(id: payload.sessionId, cwd: payload.cwd)
                    if !manager.pendingPermissions.contains(where: { $0.id == requestId }) {
                        manager.pendingPermissions.append(req)
                    }
                    manager.sessions[payload.sessionId]?.apply(.permissionRequested(req))
                    SoundManager.shared.play(.permissionNeeded)
                }

                let decision = await manager.permissionService.awaitDecision(for: requestId)

                await MainActor.run {
                    manager.pendingPermissions.removeAll { $0.id == requestId }
                }

                switch decision {
                case .allow: return .allow(hookEvent: "PermissionRequest")
                case .bypass: return .allow(hookEvent: "PermissionRequest")
                case .deny(let reason): return .deny(hookEvent: "PermissionRequest", reason: reason)
                }
            }

            do {
                try await server.start()
            } catch {
                print("[AgentPulse] ❌ Server failed: \(error)")
            }
        }

        cleanupTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { break }
                let beforeHeartbeat = self.agentManager.activeSessions.count
                self.agentManager.heartbeatCheck()
                let afterHeartbeat = self.agentManager.activeSessions.count
                if afterHeartbeat < beforeHeartbeat {
                    SoundManager.shared.play(.agentError)
                }
                self.agentManager.cleanupStaleSessions()
                self.agentManager.cleanupTestSessions()
                // Every ~60s, re-scan for processes we may have missed or
                // whose sessions got cleaned up while still alive.
                tick += 1
                if tick % 2 == 0 {
                    self.agentManager.rediscover()
                }
            }
        }

        // File watcher for near-instant transcript refresh (~10ms latency).
        // The 30s poll below serves as a fallback in case the watcher misses
        // a write (e.g., file was replaced instead of appended).
        agentManager.installTranscriptWatcher()

        print("[AgentPulse] ✅ Services started")
    }

    // MARK: - Notch UI

    private func setupNotchUI() {
        let panel = NotchPanel(agentManager: agentManager)
        panel.setup()
        self.notchPanel = panel
        observeTask = observeAgentState(panel: panel)

        // Initial state: check if there are already sessions
        updatePanelState(panel: panel)

        installDebugHandler()

        print("[AgentPulse] ✅ Notch UI ready")
    }

    /// Wires the HookHTTPServer's `debugHandler` to live AgentManager + NotchPanel
    /// state. Lets us drive the entire UI from `curl` instead of mouse simulation.
    private func installDebugHandler() {
        let server = hookServer
        let manager = agentManager
        Task.detached { [weak self] in
            await server.setDebugHandler { command in
                await MainActor.run {
                    self?.handleDebugCommand(command, manager: manager) ?? "{\"error\":\"appstate gone\"}"
                }
            }
        }
    }

    /// Single-line JSON-string command interpreter for /debug/* routes.
    @MainActor
    private func handleDebugCommand(_ command: String, manager: AgentManager) -> String {
        let panel = notchPanel

        switch command {
        case "state":
            let state = panel?.panelState.displayState ?? .dormant
            let sessions = manager.sessions.count
            let active = manager.activeSessions.count
            let perms = manager.pendingPermissions.count
            let windowVisible = panel?.debugIsPanelVisible ?? false
            let windowFrame = panel?.debugPanelFrame ?? .zero
            let frameStr = "\(windowFrame.origin.x),\(windowFrame.origin.y),\(windowFrame.width),\(windowFrame.height)"
            return """
            {"display_state":"\(state)","sessions_total":\(sessions),"sessions_active":\(active),"pending_permissions":\(perms),"window_visible":\(windowVisible),"window_frame":"\(frameStr)"}
            """

        case "set:dormant":
            panel?.transitionToDormant()
            return "{\"ok\":true,\"state\":\"dormant\"}"
        case "set:compact":
            panel?.transitionToCompact()
            return "{\"ok\":true,\"state\":\"compact\"}"
        case "set:expanded":
            panel?.transitionToExpanded()
            return "{\"ok\":true,\"state\":\"expanded\"}"

        case "sessions":
            let sessions = manager.activeSessions.map { s -> String in
                let prompt = s.lastUserPrompt?.replacingOccurrences(of: "\"", with: "'") ?? ""
                let promptShort = String(prompt.prefix(80))
                return "{\"id\":\"\(s.id.prefix(8))\",\"project\":\"\(s.projectName)\",\"status\":\"\(s.status)\",\"agent\":\"\(s.agentKind)\",\"prompt\":\"\(promptShort)\"}"
            }
            return "{\"count\":\(sessions.count),\"sessions\":[\(sessions.joined(separator: ","))]}"

        case "permissions:clear":
            let count = manager.pendingPermissions.count
            for req in manager.pendingPermissions { manager.denyPermission(id: req.id, reason: "debug clear") }
            return "{\"cleared\":\(count)}"

        case "permissions:approve":
            let count = manager.pendingPermissions.count
            for req in manager.pendingPermissions { manager.approvePermission(id: req.id) }
            return "{\"approved\":\(count)}"

        case "sessions:clear":
            let count = manager.sessions.count
            manager.debugRemoveAllSessions()
            return "{\"cleared\":\(count)}"

        case "sessions:cleanup-test":
            manager.cleanupTestSessions()
            return "{\"ok\":true}"

        case "screens":
            let entries = NSScreen.screens.enumerated().map { idx, s -> String in
                let main = (s == NSScreen.main) ? "true" : "false"
                let name = s.localizedName.replacingOccurrences(of: "\"", with: "'")
                let frame = "\(s.frame.origin.x),\(s.frame.origin.y),\(s.frame.width),\(s.frame.height)"
                return "{\"idx\":\(idx),\"name\":\"\(name)\",\"frame\":\"\(frame)\",\"hasNotch\":\(s.hasNotch),\"main\":\(main),\"safeAreaTop\":\(s.safeAreaInsets.top)}"
            }
            let pref = DisplayPreference.preferredName ?? ""
            return "{\"count\":\(NSScreen.screens.count),\"preferred\":\"\(pref)\",\"screens\":[\(entries.joined(separator: ","))]}"

        case let cmd where cmd.hasPrefix("display:set:"):
            let name = String(cmd.dropFirst("display:set:".count))
            panel?.applyDisplayPreference(name.isEmpty ? nil : name)
            return "{\"ok\":true,\"preferred\":\"\(name)\"}"

        case let cmd where cmd.hasPrefix("hittest:"):
            // hittest:x,y — returns whether (x,y) in NSScreen coords is
            // inside the live silhouette right now.
            let coords = cmd.dropFirst("hittest:".count).split(separator: ",")
            guard coords.count == 2,
                  let x = Double(coords[0]),
                  let y = Double(coords[1]),
                  let panel else {
                return "{\"error\":\"hittest needs x,y\"}"
            }
            let inside = panel.debugIsMouseInsideSilhouette(x: x, y: y)
            return "{\"x\":\(x),\"y\":\(y),\"inside\":\(inside),\"state\":\"\(panel.panelState.displayState)\"}"

        case "cursor":
            let mouse = NSEvent.mouseLocation
            let inside = panel?.debugIsMouseInsideSilhouette(x: Double(mouse.x), y: Double(mouse.y)) ?? false
            let state = panel?.panelState.displayState ?? .dormant
            let cursorScreenName = NSScreen.screens.first(where: { $0.frame.contains(mouse) })?.localizedName ?? "?"
            let panelScreenName = panel?.debugPanelScreen ?? "?"
            return "{\"cursor_x\":\(Int(mouse.x)),\"cursor_y\":\(Int(mouse.y)),\"cursor_screen\":\"\(cursorScreenName)\",\"panel_screen\":\"\(panelScreenName)\",\"state\":\"\(state)\",\"inside\":\(inside)}"

        case "test:permission":
            let id = "debug-perm-\(Int.random(in: 1000...9999))"
            let req = PermissionRequest(
                id: id,
                sessionId: "debug-session",
                toolName: "Bash",
                toolInput: ["command": AnyCodable("echo 'hello from debug'")],
                cwd: "/tmp/debug",
                receivedAt: .now
            )
            manager.getOrCreateSession(id: "debug-session", cwd: "/tmp/debug")
            if !manager.pendingPermissions.contains(where: { $0.id == id }) {
                manager.pendingPermissions.append(req)
            }
            return "{\"ok\":true,\"id\":\"\(id)\"}"

        case "test:many-sessions":
            for i in 0..<5 {
                let id = "fake-\(i)"
                let cwd = "/Users/voya/projects/demo-project-\(i)"
                let session = manager.getOrCreateSession(id: id, cwd: cwd)
                session.status = (i == 0 ? .active : (i == 1 ? .waitingForInput : .idle))
                session.lastUserPrompt = "Sample prompt #\(i): refactor the auth middleware to use the new token storage scheme"
            }
            return "{\"ok\":true,\"added\":5}"

        default:
            return "{\"error\":\"unknown command: \(command)\"}"
        }
    }

    // MARK: - State Machine Driver

    /// Observes agentManager changes and drives panel state transitions.
    ///
    /// Implementation note: `withObservationTracking` only re-fires for the
    /// specific property accesses that happen inside its closure. Reading
    /// just `activeSessions.first?.status` would miss status changes on the
    /// 2nd, 3rd, … sessions. We touch every session's `status` so any of
    /// them flipping wakes us up.
    private func observeAgentState(panel: NotchPanel) -> Task<Void, Never> {
        let manager = agentManager
        return Task { @MainActor in
            // Check initial state
            self.updatePanelState(panel: panel)

            while !Task.isCancelled {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = manager.activeSessions.count
                        _ = manager.pendingPermissions.count
                        // Touch every session's status, not just the first.
                        for session in manager.activeSessions {
                            _ = session.status
                        }
                    } onChange: {
                        cont.resume()
                    }
                }
                self.updatePanelState(panel: panel)
            }
        }
    }

    /// Determine the correct panel state from current agent data. Plays sounds on transitions.
    ///
    /// Design note: we **never** auto-expand. Even when a permission arrives,
    /// we stay in compact mode and let the pill text + colour communicate
    /// the alert (orange dot, "1 needs input"). The earlier auto-action
    /// behaviour was disruptive — it grabbed the user's mouse area without
    /// warning, made the silhouette huge, and people perceived their hover
    /// trigger zone as enormous. The user has to deliberately hover the
    /// small pill to act on the permission.
    private func updatePanelState(panel: NotchPanel) {
        let sessions = agentManager.activeSessions
        let currentState = panel.panelState.displayState

        switch currentState {
        case .dormant:
            panel.transitionToCompact()
            if !sessions.isEmpty {
                SoundManager.shared.play(.agentStarted)
            }
        case .compact, .expanded:
            break
        }

        // Permission alert sound — only when count increases (0→1, 1→2, etc.)
        let permCount = agentManager.pendingPermissions.count
        if permCount > lastKnownPermCount {
            SoundManager.shared.play(.permissionNeeded)
        }
        lastKnownPermCount = permCount
    }

    func stop() {
        serverTask?.cancel()
        cleanupTask?.cancel()
        observeTask?.cancel()
        agentManager.transcriptWatcher?.unwatchAll()

        // denyAll() unblocks waiting bridge continuations (operates on the
        // PermissionService actor's own dict). removeAll() clears the UI-
        // facing list. Both are needed; the Task means denyAll() runs
        // asynchronously but that's fine — it doesn't depend on the array.
        Task { await agentManager.permissionService.denyAll() }
        agentManager.pendingPermissions.removeAll()

        notchPanel?.teardown()
        notchPanel?.hide()
    }
}

extension HookHTTPServer {
    func setEventHandler(_ handler: @escaping @Sendable (HookEvent) async -> HookResponse) {
        self.eventHandler = handler
    }

    func setApprovalHandler(_ handler: @escaping @Sendable (HookPayload, String) async -> HookResponse) {
        self.approvalHandler = handler
    }

    func setDebugHandler(_ handler: @escaping @Sendable (String) async -> String) {
        self.debugHandler = handler
    }
}
