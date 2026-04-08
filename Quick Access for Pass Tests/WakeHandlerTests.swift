import Testing
import Foundation
@testable import Quick_Access_for_Pass

/// Tests the decision branches of `WakeHandler.handle(...)` that are
/// reachable from the wake recovery path.
///
/// `AutoHealStateMachine.recordWakeFailure(now:)` only returns three
/// of the four `AutoHealStateMachine.Decision` cases: `.ignore`,
/// `.markUnreachable`, or `.restart`. The fourth case (`.markDegraded`)
/// is reachable only from `recordFailure`, not from wake handling, so
/// WakeHandler's `.markDegraded` branch is dead code on the wake path.
/// We keep it in the helper for symmetry with future non-wake uses but
/// do not test it here.
///
/// `AutoHealStateMachine` and `ProxyGuardState` are `@MainActor`-
/// isolated under the project's `-default-isolation MainActor` flag.
/// The suite is marked `@MainActor` to match the existing
/// `ProxyCoordinatorGuardTests` convention.
@MainActor
struct WakeHandlerTests {

    @Test("healthy outcome records healthy and calls onHealthy")
    func healthyRecordsAndCallsOnHealthy() async {
        var autoHeal = AutoHealStateMachine()
        var guardState = ProxyGuardState()
        var healthyCalls = 0
        var degradedCalls = 0
        var unreachableCalls = 0
        var restartCalls = 0

        await WakeHandler.handle(
            outcome: .healthy,
            callbacks: .init(
                recordHealthy: { autoHeal.recordHealthy() },
                recordWakeFailure: { autoHeal.recordWakeFailure(now: Date()) },
                guardBeginRestart: { guardState.beginRestart() },
                guardEndRestart: { guardState.endRestart() },
                autoHealBeginRestart: { autoHeal.beginRestart() },
                autoHealEndRestart: { autoHeal.endRestart(now: Date()) },
                onHealthy: { healthyCalls += 1 },
                onDegraded: { degradedCalls += 1 },
                onUnreachable: { unreachableCalls += 1 },
                restart: { restartCalls += 1 }
            )
        )

        #expect(healthyCalls == 1)
        #expect(degradedCalls == 0)
        #expect(unreachableCalls == 0)
        #expect(restartCalls == 0)
    }

    @Test("unhealthy .ignore decision fires nothing (restart already in flight)")
    func unhealthyIgnoreFiresNothing() async {
        var autoHeal = AutoHealStateMachine()
        var guardState = ProxyGuardState()

        // Seed: AutoHealStateMachine returns .ignore when isRestarting is true.
        autoHeal.beginRestart()

        var healthyCalls = 0
        var degradedCalls = 0
        var unreachableCalls = 0
        var restartCalls = 0

        await WakeHandler.handle(
            outcome: .unhealthy,
            callbacks: .init(
                recordHealthy: { autoHeal.recordHealthy() },
                recordWakeFailure: { autoHeal.recordWakeFailure(now: Date()) },
                guardBeginRestart: { guardState.beginRestart() },
                guardEndRestart: { guardState.endRestart() },
                autoHealBeginRestart: { autoHeal.beginRestart() },
                autoHealEndRestart: { autoHeal.endRestart(now: Date()) },
                onHealthy: { healthyCalls += 1 },
                onDegraded: { degradedCalls += 1 },
                onUnreachable: { unreachableCalls += 1 },
                restart: { restartCalls += 1 }
            )
        )

        #expect(healthyCalls == 0)
        #expect(degradedCalls == 0)
        #expect(unreachableCalls == 0)
        #expect(restartCalls == 0)
    }

    @Test("unhealthy .restart decision fires onDegraded then restart")
    func unhealthyRestartFiresDegradedThenRestart() async {
        var autoHeal = AutoHealStateMachine()
        var guardState = ProxyGuardState()

        // A fresh AutoHealStateMachine returns .restart from
        // recordWakeFailure on the first unhealthy wake (no cooldown,
        // not restarting — the default path for wake failures).
        var healthyCalls = 0
        var degradedCalls = 0
        var unreachableCalls = 0
        var restartCalls = 0

        await WakeHandler.handle(
            outcome: .unhealthy,
            callbacks: .init(
                recordHealthy: { autoHeal.recordHealthy() },
                recordWakeFailure: { autoHeal.recordWakeFailure(now: Date()) },
                guardBeginRestart: { guardState.beginRestart() },
                guardEndRestart: { guardState.endRestart() },
                autoHealBeginRestart: { autoHeal.beginRestart() },
                autoHealEndRestart: { autoHeal.endRestart(now: Date()) },
                onHealthy: { healthyCalls += 1 },
                onDegraded: { degradedCalls += 1 },
                onUnreachable: { unreachableCalls += 1 },
                restart: { restartCalls += 1 }
            )
        )

        #expect(healthyCalls == 0)
        #expect(degradedCalls == 1, "onDegraded fires as pre-restart status update")
        #expect(unreachableCalls == 0)
        #expect(restartCalls == 1)
    }

    @Test("unhealthy .restart rejected by guardState.beginRestart fires onDegraded but NOT restart")
    func unhealthyRestartRejectedByGuardState() async {
        var autoHeal = AutoHealStateMachine()
        var guardState = ProxyGuardState()

        // Seed guardState so beginRestart() returns false (restart
        // already in flight on the coordinator side). WakeHandler's
        // `.restart` branch should bail out of the guard without
        // calling `restart` closure or `onDegraded`.
        _ = guardState.beginRestart()  // first call sets in-flight, returns true

        var healthyCalls = 0
        var degradedCalls = 0
        var unreachableCalls = 0
        var restartCalls = 0

        await WakeHandler.handle(
            outcome: .unhealthy,
            callbacks: .init(
                recordHealthy: { autoHeal.recordHealthy() },
                recordWakeFailure: { autoHeal.recordWakeFailure(now: Date()) },
                guardBeginRestart: { guardState.beginRestart() },
                guardEndRestart: { guardState.endRestart() },
                autoHealBeginRestart: { autoHeal.beginRestart() },
                autoHealEndRestart: { autoHeal.endRestart(now: Date()) },
                onHealthy: { healthyCalls += 1 },
                onDegraded: { degradedCalls += 1 },
                onUnreachable: { unreachableCalls += 1 },
                restart: { restartCalls += 1 }
            )
        )

        #expect(healthyCalls == 0)
        #expect(unreachableCalls == 0)
        #expect(restartCalls == 0, "guardState rejected the restart, so restart closure must not fire")
    }

    @Test("unhealthy .markUnreachable decision fires onUnreachable")
    func unhealthyMarkUnreachableFiresOnUnreachable() async {
        var autoHeal = AutoHealStateMachine()
        var guardState = ProxyGuardState()

        // Seed: push the state machine into cooldown by recording a
        // recent restart. After endRestart(now: Date()), the cooldown
        // window is active and recordWakeFailure returns .markUnreachable.
        autoHeal.beginRestart()
        autoHeal.endRestart(now: Date())

        var healthyCalls = 0
        var degradedCalls = 0
        var unreachableCalls = 0
        var restartCalls = 0

        await WakeHandler.handle(
            outcome: .unhealthy,
            callbacks: .init(
                recordHealthy: { autoHeal.recordHealthy() },
                recordWakeFailure: { autoHeal.recordWakeFailure(now: Date()) },
                guardBeginRestart: { guardState.beginRestart() },
                guardEndRestart: { guardState.endRestart() },
                autoHealBeginRestart: { autoHeal.beginRestart() },
                autoHealEndRestart: { autoHeal.endRestart(now: Date()) },
                onHealthy: { healthyCalls += 1 },
                onDegraded: { degradedCalls += 1 },
                onUnreachable: { unreachableCalls += 1 },
                restart: { restartCalls += 1 }
            )
        )

        #expect(healthyCalls == 0)
        #expect(degradedCalls == 0)
        #expect(unreachableCalls == 1)
        #expect(restartCalls == 0)
    }
}
