import Testing
@testable import AgentPulseCore

@Suite("AgentSession Reducer")
struct AgentSessionReducerTests {
    private func makeSession() -> AgentSession {
        AgentSession(id: "test-1", cwd: "/tmp/test")
    }

    private func makeTool(id: String = "tool-1", name: String = "Bash") -> ToolCall {
        ToolCall(id: id, toolName: name, toolInput: [:], startTime: .now, status: .running)
    }

    // MARK: - Tool lifecycle

    @Test func toolStartedSetsActive() {
        let s = makeSession()
        s.status = .idle
        s.apply(.toolStarted(makeTool()))
        #expect(s.status == .active)
        #expect(s.currentToolCall != nil)
    }

    @Test func toolSucceededSetsActive() {
        let s = makeSession()
        s.apply(.toolStarted(makeTool()))
        s.apply(.toolSucceeded(toolUseId: "tool-1"))
        #expect(s.status == .active)
        #expect(s.recentTools.count == 1)
    }

    @Test func toolFailedResetsToActive() {
        let s = makeSession()
        s.apply(.toolStarted(makeTool()))
        s.apply(.toolFailed(reason: "oops", toolUseId: "tool-1"))
        #expect(s.status == .active)
        #expect(s.recentTools.count == 1)
    }

    // MARK: - Permission lifecycle

    @Test func permissionRequestedSetsWaiting() {
        let s = makeSession()
        let req = PermissionRequest(
            toolUseId: "tool-1", sessionId: "test-1",
            toolName: "Bash", toolInput: [:], cwd: "/tmp", receivedAt: .now
        )
        s.apply(.permissionRequested(req))
        #expect(s.status == .waitingForPermission)
        #expect(s.pendingPermission?.id == req.id)
    }

    @Test func permissionResolvedAlwaysSetsActive() {
        let s = makeSession()
        let req = PermissionRequest(
            toolUseId: "tool-1", sessionId: "test-1",
            toolName: "Bash", toolInput: [:], cwd: "/tmp", receivedAt: .now
        )
        s.apply(.permissionRequested(req))
        // Simulate a notification arriving while waiting
        s.apply(.notified)
        #expect(s.status == .waitingForInput)
        // Now resolve — should go to .active even though we weren't
        // .waitingForPermission anymore
        s.apply(.permissionResolved)
        #expect(s.status == .active)
        #expect(s.pendingPermission == nil)
    }

    // MARK: - Session end

    @Test func sessionEndedClearsPendingQuestion() {
        let s = makeSession()
        let q = AskUserQuestion(questions: [
            .init(question: "Pick one", header: nil, multiSelect: false, options: [])
        ])
        s.apply(.questionAsked(q, toolUseId: "tool-1"))
        #expect(s.pendingQuestion != nil)
        s.apply(.sessionEnded)
        #expect(s.pendingQuestion == nil)
        #expect(s.status == .done)
    }

    // MARK: - Question lifecycle

    @Test func questionAskedMatchesByToolUseId() {
        let s = makeSession()
        let q = AskUserQuestion(questions: [
            .init(question: "Pick one", header: nil, multiSelect: false, options: [])
        ])
        s.apply(.questionAsked(q, toolUseId: "ask-1"))
        #expect(s.pendingQuestion != nil)
        #expect(s.pendingQuestionToolUseId == "ask-1")

        // A different tool succeeding should NOT clear the question
        s.apply(.toolSucceeded(toolUseId: "other-tool"))
        #expect(s.pendingQuestion != nil)

        // The matching tool succeeding SHOULD clear the question
        s.apply(.toolSucceeded(toolUseId: "ask-1"))
        #expect(s.pendingQuestion == nil)
    }

    // MARK: - Stopped

    @Test func stoppedClearsToolAndQuestion() {
        let s = makeSession()
        s.apply(.toolStarted(makeTool()))
        let q = AskUserQuestion(questions: [
            .init(question: "x", header: nil, multiSelect: false, options: [])
        ])
        s.apply(.questionAsked(q, toolUseId: "ask-1"))
        s.apply(.stopped)
        #expect(s.status == .waitingForInput)
        #expect(s.currentToolCall == nil)
        #expect(s.pendingQuestion == nil)
        #expect(s.pendingQuestionToolUseId == nil)
    }

    // MARK: - Subagents

    @Test func subagentLifecycle() {
        let s = makeSession()
        s.apply(.subagentStarted(id: "child-1"))
        #expect(s.subagentIds == ["child-1"])
        s.apply(.subagentStarted(id: "child-2"))
        #expect(s.subagentIds == ["child-1", "child-2"])
        s.apply(.subagentStopped)
        #expect(s.subagentIds == ["child-1"])
        s.apply(.subagentStopped)
        #expect(s.subagentIds.isEmpty)
        // Extra stop on empty array is safe
        s.apply(.subagentStopped)
        #expect(s.subagentIds.isEmpty)
    }

    // MARK: - Recent tools overflow

    @Test func recentToolsCapsAtFive() {
        let s = makeSession()
        for i in 0..<7 {
            let tool = makeTool(id: "t-\(i)", name: "Tool\(i)")
            s.apply(.toolStarted(tool))
            s.apply(.toolSucceeded(toolUseId: "t-\(i)"))
        }
        #expect(s.recentTools.count == 5)
        // Newest first
        #expect(s.recentTools[0].id == "t-6")
        #expect(s.recentTools[4].id == "t-2")
    }

    // MARK: - Nil toolUseId should not clear question

    @Test func nilToolUseIdDoesNotClearQuestion() {
        let s = makeSession()
        let q = AskUserQuestion(questions: [
            .init(question: "x", header: nil, multiSelect: false, options: [])
        ])
        s.apply(.questionAsked(q, toolUseId: "ask-1"))
        s.apply(.toolSucceeded(toolUseId: nil))
        #expect(s.pendingQuestion != nil)
        s.apply(.toolFailed(reason: "err", toolUseId: nil))
        #expect(s.pendingQuestion != nil)
    }

    // MARK: - User prompt resets

    @Test func userPromptSubmittedClearsState() {
        let s = makeSession()
        s.apply(.toolStarted(makeTool()))
        let q = AskUserQuestion(questions: [
            .init(question: "x", header: nil, multiSelect: false, options: [])
        ])
        s.apply(.questionAsked(q, toolUseId: "ask-1"))
        s.apply(.userPromptSubmitted)
        #expect(s.status == .active)
        #expect(s.currentToolCall == nil)
        #expect(s.pendingQuestion == nil)
        #expect(s.recentTools.isEmpty)
    }
}

@Suite("isResolutionEvent")
struct ResolutionEventTests {
    @Test func resolutionEvents() {
        #expect(AgentSession.isResolutionEvent(.toolSucceeded(toolUseId: nil)))
        #expect(AgentSession.isResolutionEvent(.toolFailed(reason: "", toolUseId: nil)))
        #expect(AgentSession.isResolutionEvent(.stopped))
        #expect(AgentSession.isResolutionEvent(.sessionEnded))
    }

    @Test func nonResolutionEvents() {
        #expect(!AgentSession.isResolutionEvent(.sessionStarted))
        #expect(!AgentSession.isResolutionEvent(.toolStarted(
            ToolCall(id: "x", toolName: "Bash", toolInput: [:], startTime: .now, status: .running)
        )))
        #expect(!AgentSession.isResolutionEvent(.permissionRequested(
            PermissionRequest(toolUseId: "x", sessionId: "s", toolName: "Bash", toolInput: [:], cwd: "/", receivedAt: .now)
        )))
        #expect(!AgentSession.isResolutionEvent(.permissionResolved))
        #expect(!AgentSession.isResolutionEvent(.notified))
        #expect(!AgentSession.isResolutionEvent(.subagentStarted(id: "x")))
        #expect(!AgentSession.isResolutionEvent(.subagentStopped))
        #expect(!AgentSession.isResolutionEvent(.userPromptSubmitted))
        let q = AskUserQuestion(questions: [
            .init(question: "x", header: nil, multiSelect: false, options: [])
        ])
        #expect(!AgentSession.isResolutionEvent(.questionAsked(q, toolUseId: nil)))
    }
}
