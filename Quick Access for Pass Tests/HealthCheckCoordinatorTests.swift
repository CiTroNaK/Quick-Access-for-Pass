// Quick Access for Pass Tests/HealthCheckCoordinatorTests.swift
import Testing
import Foundation
@testable import Quick_Access_for_Pass

@Suite("HealthCheckCoordinator")
@MainActor
struct HealthCheckCoordinatorTests {

    private struct Harness {
        let coordinator: HealthCheckCoordinator
        let cliStore: PassCLIStatusStore
        let runDispatcher: FakeRunProxyDispatcher
        let sshDispatcher: FakeSSHProxyDispatcher
        let cliChecker: FakePassCLIHealthChecker
        let runChecker: FakeRunProbeChecker
        let sshChecker: FakeSSHProbeChecker
    }

    private func makeHarness() -> Harness {
        let cliStore = PassCLIStatusStore()
        let cliService = PassCLIService(cliPath: "/bin/false")
        let runDispatcher = FakeRunProxyDispatcher()
        let sshDispatcher = FakeSSHProxyDispatcher()
        let cliChecker = FakePassCLIHealthChecker()
        let runChecker = FakeRunProbeChecker()
        let sshChecker = FakeSSHProbeChecker()

        let coordinator = HealthCheckCoordinator(
            cliStore: cliStore,
            cliService: cliService,
            cliChecker: cliChecker,
            runChecker: runChecker,
            sshChecker: sshChecker,
            runCoordinator: runDispatcher,
            sshCoordinator: sshDispatcher
        )

        return Harness(
            coordinator: coordinator,
            cliStore: cliStore,
            runDispatcher: runDispatcher,
            sshDispatcher: sshDispatcher,
            cliChecker: cliChecker,
            runChecker: runChecker,
            sshChecker: sshChecker
        )
    }

    // MARK: - Flow A: CLI tick

    @Test("cliTick writes store and dispatches transition on health change")
    func cliTickWritesStoreAndDispatchesTransition() async {
        let h = makeHarness()
        h.cliStore.health = .notLoggedIn
        h.runDispatcher.lastEnabled = true

        h.cliChecker.nextOutcome = PassCLIProbeOutcome(health: .ok, identity: nil, version: nil)

        await h.coordinator.tickCLI()

        #expect(h.cliStore.health == .ok)
        #expect(h.runDispatcher.cliTransitions == [.ok])
        #expect(h.sshDispatcher.cliTransitions == [.ok])
    }

    @Test("cliTick skips dispatch if result is unchanged")
    func cliTickSkipsDispatchIfResultUnchanged() async {
        let h = makeHarness()
        h.cliStore.health = .ok
        h.runDispatcher.lastEnabled = true

        h.cliChecker.nextOutcome = PassCLIProbeOutcome(health: .ok, identity: nil, version: nil)

        await h.coordinator.tickCLI()

        // No dispatch fired because the tick found no transition (previous == result).
        #expect(h.runDispatcher.cliTransitions.isEmpty)
        #expect(h.sshDispatcher.cliTransitions.isEmpty)
    }

    // MARK: - Flow B/C: hard gate

    @Test("runTick skipped when CLI is not ok")
    func runTickSkippedWhenCLINotOk() async {
        let h = makeHarness()
        h.cliStore.health = .notLoggedIn
        h.runDispatcher.lastEnabled = true
        h.runDispatcher.isProxyLive = true
        h.runChecker.nextResult = .healthy

        await h.coordinator.tickRun()

        #expect(h.runChecker.callCount == 0)
        #expect(h.runDispatcher.probeResults.isEmpty)
    }

    @Test("sshTick skipped when CLI is not ok")
    func sshTickSkippedWhenCLINotOk() async {
        let h = makeHarness()
        h.cliStore.health = .notLoggedIn
        h.sshDispatcher.lastEnabled = true
        h.sshDispatcher.isProxyLive = true
        h.sshChecker.nextResult = .healthy(identityCount: 2)

        await h.coordinator.tickSSH()

        #expect(h.sshChecker.callCount == 0)
        #expect(h.sshDispatcher.probeResults.isEmpty)
    }

    // MARK: - Flow B/C: second gate (proxy lifecycle)

    @Test("runTick skipped when proxy is not live")
    func runTickSkippedWhenProxyNil() async {
        let h = makeHarness()
        h.cliStore.health = .ok
        h.runDispatcher.lastEnabled = true
        // isProxyLive stays false — the second gate should catch the tick.

        await h.coordinator.tickRun()

        #expect(h.runChecker.callCount == 0)
        #expect(h.runDispatcher.probeResults.isEmpty)
    }

    @Test("sshTick skipped when proxy is not live")
    func sshTickSkippedWhenProxyNil() async {
        let h = makeHarness()
        h.cliStore.health = .ok
        h.sshDispatcher.lastEnabled = true
        // isProxyLive stays false.

        await h.coordinator.tickSSH()

        #expect(h.sshChecker.callCount == 0)
        #expect(h.sshDispatcher.probeResults.isEmpty)
    }

    // MARK: - Flow D: transition fanout

    @Test("cliTransition ok→failed fans out to both dispatchers")
    func cliTransitionOkToFailedFansOutToBothProxies() async {
        let h = makeHarness()
        h.cliStore.health = .ok
        h.runDispatcher.lastEnabled = true
        h.sshDispatcher.lastEnabled = true

        h.cliChecker.nextOutcome = PassCLIProbeOutcome(
            health: .failed(reason: "test"),
            identity: nil,
            version: nil
        )

        await h.coordinator.tickCLI()

        #expect(h.runDispatcher.cliTransitions == [.failed(reason: "test")])
        #expect(h.sshDispatcher.cliTransitions == [.failed(reason: "test")])
    }

    @Test("cliTransition failed→ok dispatches .ok to both dispatchers")
    func cliTransitionFailedToOkTriggersSSHRecoverProxyIfNeeded() async {
        let h = makeHarness()
        h.cliStore.health = .failed(reason: "stale")
        h.runDispatcher.lastEnabled = true
        h.sshDispatcher.lastEnabled = true

        h.cliChecker.nextOutcome = PassCLIProbeOutcome(health: .ok, identity: nil, version: nil)

        await h.coordinator.tickCLI()

        // Coordinator dispatched .ok to both. Whether recoverProxyIfNeeded
        // actually ran is a concern of SSHProxyCoordinator, tested separately
        // in SSHProxyCoordinatorTests.cliOkWithNilProxyAttemptsRestart.
        #expect(h.runDispatcher.cliTransitions == [.ok])
        #expect(h.sshDispatcher.cliTransitions == [.ok])
    }

    // MARK: - Flow E: refreshAll

    @Test("refreshAll fires the CLI checker and the Run/SSH checkers when live")
    func refreshAllFiresOneTickOfEachChecker() async {
        let h = makeHarness()
        h.cliStore.health = .ok
        h.runDispatcher.lastEnabled = true
        h.runDispatcher.isProxyLive = true
        h.sshDispatcher.lastEnabled = true
        h.sshDispatcher.isProxyLive = true
        h.cliChecker.nextOutcome = PassCLIProbeOutcome(health: .ok, identity: nil, version: nil)

        await h.coordinator.refreshAll()

        #expect(h.cliChecker.callCount == 1)
        #expect(h.runChecker.callCount == 1)
        #expect(h.sshChecker.callCount == 1)
    }

    // MARK: - start() / cancel() lifecycle

    @Test("start runs CLI probe synchronously before spawning loops")
    func startRunsCLIProbeSynchronouslyBeforeSpawningLoops() async {
        let h = makeHarness()
        h.cliChecker.nextOutcome = PassCLIProbeOutcome(
            health: .notLoggedIn, identity: nil, version: nil
        )

        await h.coordinator.start()

        #expect(h.cliStore.health == .notLoggedIn)
        #expect(h.cliChecker.callCount >= 1)
        #expect(h.coordinator.debugCLITaskIsLive)
        #expect(h.coordinator.debugRunTaskIsLive)
        #expect(h.coordinator.debugSSHTaskIsLive)

        h.coordinator.cancel()
    }

    @Test("cancel cancels all tasks")
    func cancelCancelsAllTasks() async {
        let h = makeHarness()
        h.cliChecker.nextOutcome = PassCLIProbeOutcome(health: .ok, identity: nil, version: nil)

        await h.coordinator.start()
        #expect(h.coordinator.debugCLITaskIsLive)

        h.coordinator.cancel()

        #expect(h.coordinator.debugCLITaskIsLive == false)
        #expect(h.coordinator.debugRunTaskIsLive == false)
        #expect(h.coordinator.debugSSHTaskIsLive == false)
    }

    // MARK: - handleSystemWake

    @Test("handleSystemWake triggers refreshAll and per-proxy wake hooks")
    func handleSystemWakeTriggersRefreshAllAndProxyWakeHooks() async {
        let h = makeHarness()
        h.cliStore.health = .ok
        h.runDispatcher.lastEnabled = true
        h.sshDispatcher.lastEnabled = true
        h.cliChecker.nextOutcome = PassCLIProbeOutcome(health: .ok, identity: nil, version: nil)

        await h.coordinator.handleSystemWake()

        // refreshAll fired → CLI checker called at least once
        #expect(h.cliChecker.callCount >= 1)
        // Both per-proxy handleWake dispatches recorded
        #expect(h.runDispatcher.wakeCallCount == 1)
        #expect(h.sshDispatcher.wakeCallCount == 1)
    }

    // MARK: - EH7: start() reentrancy guard

    @Test("start called twice sequentially is a no-op on the second call")
    func startCalledTwiceSequentiallyIsNoOp() async {
        let h = makeHarness()
        h.cliChecker.nextOutcome = PassCLIProbeOutcome(health: .ok, identity: nil, version: nil)

        await h.coordinator.start()
        let callCountAfterFirstStart = h.cliChecker.callCount

        await h.coordinator.start()

        #expect(h.cliChecker.callCount == callCountAfterFirstStart)
        h.coordinator.cancel()
    }

    @Test("start called reentrantly during the initial probe is a no-op on the second call")
    func startCalledReentrantlyDuringInitialProbeIsNoOp() async {
        let h = makeHarness()

        // Use the fake's onCheck hook to kick off a second start() call
        // while the first call is still suspended inside its await tickCLI().
        // Since onCheck fires on MainActor, the nested start() runs with the
        // isStarting sentinel already set.
        h.cliChecker.onCheck = { [weak coordinator = h.coordinator] in
            Task { @MainActor in
                await coordinator?.start()
            }
        }
        h.cliChecker.nextOutcome = PassCLIProbeOutcome(health: .ok, identity: nil, version: nil)

        await h.coordinator.start()

        // Give the reentrant Task a chance to schedule and run its start() call.
        // It should hit the isStarting guard and bail without invoking the CLI
        // checker a second time.
        try? await Task.sleep(for: .milliseconds(50))

        // The reentrant call incremented callCount only if the guard failed.
        // With the guard in place, callCount should be exactly 1 from the
        // initial probe.
        #expect(h.cliChecker.callCount == 1)

        h.coordinator.cancel()
    }
}
