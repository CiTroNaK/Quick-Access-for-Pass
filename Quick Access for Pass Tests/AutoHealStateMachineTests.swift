import Testing
import Foundation
@testable import Quick_Access_for_Pass

struct AutoHealStateMachineTests {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func firstFailureMarksDegraded() {
        var sm = AutoHealStateMachine()
        #expect(sm.recordFailure(now: t0) == .markDegraded)
        #expect(sm.consecutiveFailures == 1)
    }

    @Test func secondFailureTriggersRestart() {
        var sm = AutoHealStateMachine()
        _ = sm.recordFailure(now: t0)
        #expect(sm.recordFailure(now: t0.addingTimeInterval(30)) == .restart)
    }

    @Test func healthyResetsCounter() {
        var sm = AutoHealStateMachine()
        _ = sm.recordFailure(now: t0)
        sm.recordHealthy()
        #expect(sm.consecutiveFailures == 0)
    }

    @Test func secondFailureDuringCooldownMarksUnreachable() {
        var sm = AutoHealStateMachine()
        sm.beginRestart()
        sm.endRestart(now: t0)
        _ = sm.recordFailure(now: t0.addingTimeInterval(10))
        #expect(sm.recordFailure(now: t0.addingTimeInterval(20)) == .markUnreachable)
    }

    @Test func cooldownExpiresAfter120Seconds() {
        var sm = AutoHealStateMachine()
        sm.beginRestart()
        sm.endRestart(now: t0)
        _ = sm.recordFailure(now: t0.addingTimeInterval(121))
        #expect(sm.recordFailure(now: t0.addingTimeInterval(122)) == .restart)
    }

    @Test func failuresDuringRestartAreIgnored() {
        var sm = AutoHealStateMachine()
        sm.beginRestart()
        #expect(sm.recordFailure(now: t0) == .ignore)
        #expect(sm.consecutiveFailures == 0)
    }

    @Test func wakeFailureBypassesTwoStrike() {
        var sm = AutoHealStateMachine()
        #expect(sm.recordWakeFailure(now: t0) == .restart)
    }

    @Test func wakeFailureRespectsCooldown() {
        var sm = AutoHealStateMachine()
        sm.beginRestart()
        sm.endRestart(now: t0)
        #expect(sm.recordWakeFailure(now: t0.addingTimeInterval(30)) == .markUnreachable)
    }

    @Test func endRestartResetsCounter() {
        var sm = AutoHealStateMachine()
        _ = sm.recordFailure(now: t0)
        sm.beginRestart()
        sm.endRestart(now: t0.addingTimeInterval(1))
        #expect(sm.consecutiveFailures == 0)
        #expect(sm.isRestarting == false)
    }

    @Test func restartFlagSurvivesAcrossStopStartBoundary() {
        var sm = AutoHealStateMachine()
        _ = sm.recordFailure(now: t0)
        _ = sm.recordFailure(now: t0.addingTimeInterval(1))  // .restart decision
        sm.beginRestart()
        // Simulated failure arriving between stopProxy and startProxy completion
        #expect(sm.recordFailure(now: t0.addingTimeInterval(2)) == .ignore)
        sm.endRestart(now: t0.addingTimeInterval(3))
        #expect(sm.isRestarting == false)
        #expect(sm.consecutiveFailures == 0)
    }

    @Test func cooldownBoundaryExactly120Seconds() {
        var sm = AutoHealStateMachine()
        sm.beginRestart()
        sm.endRestart(now: t0)
        _ = sm.recordFailure(now: t0.addingTimeInterval(119.9))
        #expect(sm.recordFailure(now: t0.addingTimeInterval(120.0)) == .restart,
                "at exactly 120s, cooldown should have expired")
    }
}
