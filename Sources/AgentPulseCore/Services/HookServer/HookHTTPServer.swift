import Foundation
import Hummingbird
import os

/// Local HTTP server that receives Claude Code hook events.
public actor HookHTTPServer {
    private let port: Int
    private var app: Application<RouterResponder<BasicRequestContext>>?
    public var eventHandler: (@Sendable (HookEvent) async -> HookResponse)?

    /// Called when bridge POSTs to /api/approve. Returns the decision after user clicks.
    public var approvalHandler: (@Sendable (HookPayload, String) async -> HookResponse)?

    /// Called by /debug/* endpoints to inspect or mutate runtime state
    /// without needing a real Claude Code session or mouse interaction.
    /// Implementer is expected to be `@MainActor`.
    public var debugHandler: (@Sendable (String) async -> String)?

    public init(port: Int = Constants.defaultPort) {
        self.port = port
    }

    public func start() async throws {
        let router = buildRouter()
        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname("127.0.0.1", port: port)
            )
        )
        self.app = app
        Logger.hookServer.info("Starting hook server on port \(self.port)")
        try await app.run()
    }

    /// Server lifecycle is managed by the Task running start().
    /// Cancelling that task stops the Hummingbird event loop.
    public func stop() async {
        // Hummingbird's Application.run() responds to task cancellation.
        // No explicit shutdown needed — the serverTask.cancel() in AppState handles it.
        Logger.hookServer.info("Hook server stopping")
    }

    private func buildRouter() -> Router<BasicRequestContext> {
        let router = Router()
        let handler = self

        router.post("hooks/session-start") { request, context -> Response in
            try await handler.handleRoute(request: request, context: context, eventType: .sessionStart)
        }
        router.post("hooks/session-end") { request, context -> Response in
            try await handler.handleRoute(request: request, context: context, eventType: .sessionEnd)
        }
        router.post("hooks/pre-tool-use") { request, context -> Response in
            try await handler.handleRoute(request: request, context: context, eventType: .preToolUse)
        }
        router.post("hooks/post-tool-use") { request, context -> Response in
            try await handler.handleRoute(request: request, context: context, eventType: .postToolUse)
        }
        router.post("hooks/post-tool-use-failure") { request, context -> Response in
            try await handler.handleRoute(request: request, context: context, eventType: .postToolUseFailure)
        }
        router.post("hooks/permission-request") { request, context -> Response in
            try await handler.handleRoute(request: request, context: context, eventType: .permissionRequest)
        }
        router.post("hooks/notification") { request, context -> Response in
            try await handler.handleRoute(request: request, context: context, eventType: .notification)
        }
        router.post("hooks/stop") { request, context -> Response in
            try await handler.handleRoute(request: request, context: context, eventType: .stop)
        }
        router.post("hooks/subagent-start") { request, context -> Response in
            try await handler.handleRoute(request: request, context: context, eventType: .subagentStart)
        }
        router.post("hooks/subagent-stop") { request, context -> Response in
            try await handler.handleRoute(request: request, context: context, eventType: .subagentStop)
        }

        // Bridge approval endpoint: blocks until user decides in notch UI.
        // Bridge CLI POSTs here and waits. When user clicks Allow/Deny,
        // the response is sent back and bridge forwards it to Claude Code.
        router.post("api/approve") { request, context -> Response in
            let body = try await request.body.collect(upTo: 1_048_576)
            let rawBody = String(data: Data(buffer: body), encoding: .utf8) ?? ""
            let agentType = request.headers[.init("X-Agent-Type")!] ?? "claude"
            print("[AgentPulse] 🔔 Bridge approval request from \(agentType)")

            let payload: HookPayload
            do {
                payload = try JSONDecoder().decode(HookPayload.self, from: body)
            } catch {
                print("[AgentPulse] ❌ Bridge JSON decode failed: \(error)")
                return Response(status: .ok) // Fail-open
            }

            guard let approvalHandler = await handler.approvalHandler else {
                return Response(status: .ok) // No handler → fail-open
            }

            // This BLOCKS until user clicks Allow/Deny in notch or timeout
            let hookResponse = await approvalHandler(payload, agentType)

            let data = try JSONEncoder().encode(hookResponse)
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: .init(data: data))
            )
        }

        // Health check
        router.get("health") { _, _ -> String in
            "ok"
        }

        // Debug endpoints — drive runtime state from curl, no UI clicks needed.
        // Examples:
        //   curl http://127.0.0.1:21477/debug/state
        //   curl -X POST http://127.0.0.1:21477/debug/state/expanded
        //   curl http://127.0.0.1:21477/debug/sessions
        //   curl -X POST http://127.0.0.1:21477/debug/permissions/clear
        //   curl http://127.0.0.1:21477/debug/screens
        router.get("debug/state") { _, _ -> Response in
            await Self.debugResponse(handler: handler, command: "state")
        }
        router.post("debug/state/dormant") { _, _ -> Response in
            await Self.debugResponse(handler: handler, command: "set:dormant")
        }
        router.post("debug/state/compact") { _, _ -> Response in
            await Self.debugResponse(handler: handler, command: "set:compact")
        }
        router.post("debug/state/expanded") { _, _ -> Response in
            await Self.debugResponse(handler: handler, command: "set:expanded")
        }
        router.get("debug/sessions") { _, _ -> Response in
            await Self.debugResponse(handler: handler, command: "sessions")
        }
        router.post("debug/permissions/clear") { _, _ -> Response in
            await Self.debugResponse(handler: handler, command: "permissions:clear")
        }
        router.post("debug/sessions/clear") { _, _ -> Response in
            await Self.debugResponse(handler: handler, command: "sessions:clear")
        }
        router.get("debug/screens") { _, _ -> Response in
            await Self.debugResponse(handler: handler, command: "screens")
        }
        router.get("debug/hittest") { request, _ -> Response in
            // Query string: ?x=...&y=...
            let query = request.uri.queryParameters
            let x = query["x"].flatMap { Double($0) } ?? 0
            let y = query["y"].flatMap { Double($0) } ?? 0
            return await Self.debugResponse(handler: handler, command: "hittest:\(x),\(y)")
        }
        router.get("debug/cursor") { _, _ -> Response in
            await Self.debugResponse(handler: handler, command: "cursor")
        }
        router.post("debug/display") { request, _ -> Response in
            // Body: {"name":"Built-in Retina Display"} or empty for "auto"
            let body = try await request.body.collect(upTo: 4096)
            let raw = String(data: Data(buffer: body), encoding: .utf8) ?? ""
            // Naive: extract value of "name" key
            var name = ""
            if let r = raw.range(of: "\"name\":\""),
               let end = raw.range(of: "\"", range: r.upperBound..<raw.endIndex) {
                name = String(raw[r.upperBound..<end.lowerBound])
            }
            return await Self.debugResponse(handler: handler, command: "display:set:\(name)")
        }
        router.post("debug/test/permission") { _, _ -> Response in
            await Self.debugResponse(handler: handler, command: "test:permission")
        }
        router.post("debug/test/many-sessions") { _, _ -> Response in
            await Self.debugResponse(handler: handler, command: "test:many-sessions")
        }

        // Test endpoint: simulate full bridge approval flow.
        // Open http://127.0.0.1:21477/test/approve in browser.
        // Browser will BLOCK until you click Allow/Deny in the notch.
        router.get("test/approve") { _, _ -> Response in
            let fakePayload = HookPayload(
                sessionId: "test-\(Int.random(in: 1000...9999))",
                cwd: "/Users/voya/src/vibeisland/AgentPulse",
                hookEventName: "PermissionRequest",
                toolName: "Edit",
                toolInput: [
                    "file_path": AnyCodable("src/config.ts"),
                    "old_string": AnyCodable("theme: \"light\",\nbackground: \"white\",\ntextColor: \"black\","),
                    "new_string": AnyCodable("theme: \"auto\",\nbackground: \"system\",\ntextColor: \"system\",\ndarkMode: true,"),
                ],
                toolUseId: "test-edit-\(Int.random(in: 1000...9999))",
                toolResult: nil, message: nil, title: nil,
                stopHookActive: nil, agentName: nil, agentDescription: nil,
                parentSessionId: nil, source: nil
            )
            print("[AgentPulse] 🧪 Test approval triggered — waiting for notch decision...")

            guard let approvalHandler = await handler.approvalHandler else {
                return Response(status: .ok, body: .init(byteBuffer: .init(string: "No approval handler")))
            }

            // This BLOCKS until user clicks in notch
            let response = await approvalHandler(fakePayload, "test")
            let data = try JSONEncoder().encode(response)
            print("[AgentPulse] 🧪 Test approval complete")
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: .init(data: data))
            )
        }

        return router
    }

    private enum EventType: Sendable {
        case sessionStart, sessionEnd
        case preToolUse, postToolUse, postToolUseFailure
        case permissionRequest, notification
        case stop, subagentStart, subagentStop
    }

    /// Invoke the registered debug handler and wrap its return as a JSON Response.
    private static func debugResponse(handler: HookHTTPServer, command: String) async -> Response {
        guard let debug = await handler.debugHandler else {
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: .init(string: "{\"error\":\"no debug handler\"}"))
            )
        }
        let result = await debug(command)
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(string: result))
        )
    }

    private func handleRoute(
        request: Request,
        context: BasicRequestContext,
        eventType: EventType
    ) async throws -> Response {
        let body = try await request.body.collect(upTo: 1_048_576) // 1MB max

        // Print raw request to stdout for debugging
        let rawBody = String(data: Data(buffer: body), encoding: .utf8) ?? "<binary>"
        print("[AgentPulse] 📥 \(eventType) received, body=\(rawBody.prefix(200))")

        let decoder = JSONDecoder()
        let payload: HookPayload
        do {
            payload = try decoder.decode(HookPayload.self, from: body)
        } catch {
            print("[AgentPulse] ❌ JSON decode FAILED for \(eventType): \(error)")
            print("[AgentPulse] ❌ Raw body: \(rawBody.prefix(500))")
            return Response(status: .ok)
        }

        let event: HookEvent = switch eventType {
        case .sessionStart: .sessionStart(payload)
        case .sessionEnd: .sessionEnd(payload)
        case .preToolUse: .preToolUse(payload)
        case .postToolUse: .postToolUse(payload)
        case .postToolUseFailure: .postToolUseFailure(payload)
        case .permissionRequest: .permissionRequest(payload)
        case .notification: .notification(payload)
        case .stop: .stop(payload)
        case .subagentStart: .subagentStart(payload)
        case .subagentStop: .subagentStop(payload)
        }

        print("[AgentPulse] ✅ Parsed: \(payload.hookEventName) session=\(payload.sessionId.prefix(8)) tool=\(payload.toolName ?? "none")")

        guard let handler = eventHandler else {
            return Response(status: .ok)
        }

        let hookResponse = await handler(event)

        if hookResponse.hookSpecificOutput != nil {
            let data = try JSONEncoder().encode(hookResponse)
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: .init(data: data))
            )
        }

        return Response(status: .ok)
    }
}
