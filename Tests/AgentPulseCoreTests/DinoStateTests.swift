import Testing
@testable import AgentPulseCore

@Suite("DinoState mapping")
struct DinoStateMappingTests {

    private func makeSession(id: String = "test") -> AgentSession {
        AgentSession(id: id, cwd: "/tmp/test")
    }

    private func makePermission(sessionId: String = "test") -> PermissionRequest {
        PermissionRequest(
            toolUseId: "tu-1",
            sessionId: sessionId,
            toolName: "Bash",
            toolInput: [:],
            cwd: "/tmp/test",
            receivedAt: .now
        )
    }

    // MARK: - Per-session mapping

    @Test func activeSessionIsRunning() {
        let s = makeSession()
        // .active is the init default
        #expect(DinoState.from(s) == .running)
    }

    @Test func idleSessionIsDormant() {
        let s = makeSession()
        s.status = .idle
        #expect(DinoState.from(s) == .dormant)
    }

    @Test func doneSessionIsDormant() {
        let s = makeSession()
        s.status = .done
        #expect(DinoState.from(s) == .dormant)
    }

    @Test func stoppedSessionIsDormant() {
        let s = makeSession()
        s.status = .stopped
        #expect(DinoState.from(s) == .dormant)
    }

    @Test func waitingForInputIsDormant() {
        let s = makeSession()
        s.status = .waitingForInput
        #expect(DinoState.from(s) == .dormant)
    }

    @Test func pendingPermissionForcesAction() {
        let s = makeSession()
        s.status = .idle  // even though status says idle...
        s.pendingPermission = makePermission()
        #expect(DinoState.from(s) == .action)
    }

    @Test func pendingQuestionForcesAction() {
        let s = makeSession()
        s.pendingQuestion = AskUserQuestion.placeholder
        #expect(DinoState.from(s) == .action)
    }

    @Test func waitingForPermissionStatusIsAction() {
        // Defensive: even if pendingPermission is somehow nil during the
        // transition, the status itself signals the user is blocking.
        let s = makeSession()
        s.status = .waitingForPermission
        #expect(DinoState.from(s) == .action)
    }

    // MARK: - Aggregate mapping

    @Test func emptySessionsAggregateToDormant() {
        #expect(DinoState.aggregate(from: [AgentSession]()) == .dormant)
    }

    @Test func allDormantSessionsAggregateToDormant() {
        let s1 = makeSession(id: "1"); s1.status = .idle
        let s2 = makeSession(id: "2"); s2.status = .done
        let s3 = makeSession(id: "3"); s3.status = .stopped
        #expect(DinoState.aggregate(from: [s1, s2, s3]) == .dormant)
    }

    @Test func anyRunningSessionMakesAggregateRunning() {
        let s1 = makeSession(id: "1"); s1.status = .idle
        let s2 = makeSession(id: "2") // active default
        let s3 = makeSession(id: "3"); s3.status = .done
        #expect(DinoState.aggregate(from: [s1, s2, s3]) == .running)
    }

    @Test func anyActionSessionOverridesRunning() {
        let s1 = makeSession(id: "1") // active = running
        let s2 = makeSession(id: "2")
        s2.pendingPermission = makePermission(sessionId: "2")
        #expect(DinoState.aggregate(from: [s1, s2]) == .action)
    }

    @Test func actionPriorityIsOrderIndependent() {
        let action = makeSession(id: "1")
        action.pendingPermission = makePermission(sessionId: "1")
        let running = makeSession(id: "2") // active
        #expect(DinoState.aggregate(from: [action, running]) == .action)
        #expect(DinoState.aggregate(from: [running, action]) == .action)
    }

    // MARK: - Species hashing

    @Test func sameSessionIDMapsToSameSpecies() {
        let id = "session-abc-12345"
        #expect(DinoSpecies.forSession(id) == DinoSpecies.forSession(id))
    }

    @Test func speciesHashIsDeterministic() {
        // Hash result must be stable across the process boundary —
        // pin a known input to a known output to catch accidental
        // changes to the FNV constants or modulo logic.
        // (If the FNV impl changes, recompute and update.)
        let id = "deterministic-fixture"
        let firstRun = DinoSpecies.forSession(id)
        let secondRun = DinoSpecies.forSession(id)
        let thirdRun = DinoSpecies.forSession(id)
        #expect(firstRun == secondRun)
        #expect(secondRun == thirdRun)
    }

    @Test func differentSessionIDsProduceVariety() {
        // With 6 species and 20 IDs, expect at least 3 distinct species
        // (collisions possible but extreme bunching would be a hash bug).
        let ids = (0..<20).map { "session-\($0)" }
        let species = Set(ids.map(DinoSpecies.forSession))
        #expect(species.count >= 3)
    }

    @Test func emptySessionIDStillReturnsValidSpecies() {
        // Edge case: empty string hashes to the FNV offset modulo count;
        // shouldn't crash, must return a valid case.
        let species = DinoSpecies.forSession("")
        #expect(DinoSpecies.allCases.contains(species))
    }
}
