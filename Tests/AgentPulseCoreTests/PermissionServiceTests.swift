import Testing
@testable import AgentPulseCore

@Suite("PermissionService")
struct PermissionServiceTests {
    /// Poll until the service has `n` pending continuations (deterministic, no sleep).
    private func waitForPending(_ svc: PermissionService, count: Int) async {
        for _ in 0..<200 {
            if await svc.pendingCount >= count { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func resolveBeforeAwait() async {
        let svc = PermissionService()
        await svc.resolve(requestId: "r1", decision: .allow)
        let decision = await svc.awaitDecision(for: "r1")
        #expect(decision == .allow)
    }

    @Test func resolveAfterAwait() async {
        let svc = PermissionService()
        let task = Task { await svc.awaitDecision(for: "r2") }
        await waitForPending(svc, count: 1)
        await svc.resolve(requestId: "r2", decision: .deny(reason: "nope"))
        let decision = await task.value
        #expect(decision == .deny(reason: "nope"))
    }

    @Test func doubleResolveIsNoop() async {
        let svc = PermissionService()
        let task = Task { await svc.awaitDecision(for: "r3") }
        await waitForPending(svc, count: 1)
        await svc.resolve(requestId: "r3", decision: .allow)
        await svc.resolve(requestId: "r3", decision: .deny(reason: "late"))
        let decision = await task.value
        #expect(decision == .allow)
    }

    @Test func cancellationDenies() async {
        let svc = PermissionService()
        let task = Task { await svc.awaitDecision(for: "r4") }
        await waitForPending(svc, count: 1)
        task.cancel()
        let decision = await task.value
        if case .deny = decision {
            // OK
        } else {
            Issue.record("Expected deny from cancellation, got \(decision)")
        }
    }

    @Test func denyAllResumesAll() async {
        let svc = PermissionService()
        let t1 = Task { await svc.awaitDecision(for: "d1") }
        let t2 = Task { await svc.awaitDecision(for: "d2") }
        await waitForPending(svc, count: 2)
        await svc.denyAll()
        if case .deny = await t1.value {} else { Issue.record("d1 should be deny") }
        if case .deny = await t2.value {} else { Issue.record("d2 should be deny") }
    }

}
