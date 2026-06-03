import Testing
@testable import AgentPulseCore

@Suite("StatusBadge mapping")
struct StatusBadgeTests {

    private func makeSession(id: String = "test") -> AgentSession {
        AgentSession(id: id, cwd: "/tmp/test")
    }

    private func makePermission() -> PermissionRequest {
        PermissionRequest(
            toolUseId: "tu-1", sessionId: "test", toolName: "Bash",
            toolInput: [:], cwd: "/tmp/test", receivedAt: .now
        )
    }

    @Test func activeIsWorking() {
        let s = makeSession()
        // init default = .active
        #expect(StatusBadge.from(s) == .working)
    }

    @Test func waitingForInputIsIdle() {
        // Regression test #1 — the "every card shows Working" bug.
        // Regression test #2 — afterward, waitingForInput briefly mapped
        // to .done (green / "Done"), which misled users into thinking
        // their session had ended. It hasn't; the agent is just awaiting
        // their next prompt. Correct mapping: `.idle`.
        let s = makeSession()
        s.status = .waitingForInput
        #expect(StatusBadge.from(s) == .idle)
    }

    @Test func idleStatusIsIdle() {
        let s = makeSession()
        s.status = .idle
        #expect(StatusBadge.from(s) == .idle)
    }

    @Test func doneIsDone() {
        let s = makeSession()
        s.status = .done
        #expect(StatusBadge.from(s) == .done)
    }

    @Test func stoppedIsError() {
        let s = makeSession()
        s.status = .stopped
        #expect(StatusBadge.from(s) == .error)
    }

    @Test func waitingForPermissionStatusIsWaiting() {
        let s = makeSession()
        s.status = .waitingForPermission
        #expect(StatusBadge.from(s) == .waiting)
    }

    @Test func pendingPermissionForcesWaiting() {
        let s = makeSession()
        s.status = .idle               // would otherwise be .idle badge
        s.pendingPermission = makePermission()
        #expect(StatusBadge.from(s) == .waiting)
    }

    @Test func pendingQuestionForcesWaiting() {
        let s = makeSession()
        s.status = .active             // would otherwise be .working
        s.pendingQuestion = AskUserQuestion.placeholder
        #expect(StatusBadge.from(s) == .waiting)
    }

    @Test func onlyWorkingDotPulses() {
        #expect(StatusBadge.working.shouldPulse)
        #expect(StatusBadge.waiting.shouldPulse == false)
        #expect(StatusBadge.idle.shouldPulse    == false)
        #expect(StatusBadge.done.shouldPulse    == false)
        #expect(StatusBadge.error.shouldPulse   == false)
    }

    @Test func labelsAreHumanReadable() {
        #expect(StatusBadge.working.label == "Working")
        #expect(StatusBadge.waiting.label == "Needs you")
        #expect(StatusBadge.idle.label    == "Idle")
        #expect(StatusBadge.done.label    == "Done")
        #expect(StatusBadge.error.label   == "Error")
    }
}
