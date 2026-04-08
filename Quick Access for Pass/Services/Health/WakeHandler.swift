import Foundation

/// Shared wake-recovery control flow for SSH and Run proxy coordinators.
///
/// Both coordinators respond to system wake the same way:
///
///   probe → if healthy: record + update health store
///        → if unhealthy: record wake failure → dispatch on
///          AutoHealDecision (ignore / markDegraded / markUnreachable
///          / restart)
///
/// The only per-proxy differences are the probe call (done by the
/// caller before invoking this helper), the "healthy" health-store
/// update (SSH carries a key count, Run does not), and which
/// coordinator's stop/start methods get invoked on restart. Those
/// are passed as closures grouped into ``Callbacks``.
///
/// The closure-based signature is used instead of `inout` parameters
/// because Swift 6 strict concurrency rejects passing actor-isolated
/// stored properties as `inout` across an `async` call boundary.
/// Each closure captures the mutating operation and is invoked
/// synchronously (before any suspension point) so the isolation
/// invariants are preserved.
@MainActor
enum WakeHandler {
    enum ProbeOutcome { case healthy, unhealthy }

    /// Groups the per-coordinator closures that ``handle(outcome:callbacks:)``
    /// needs. Each closure captures the coordinator's actor-isolated state.
    struct Callbacks {
        /// Calls `autoHeal.recordHealthy()` on the caller.
        var recordHealthy: () -> Void
        /// Calls `autoHeal.recordWakeFailure(now:)` and returns the decision.
        var recordWakeFailure: () -> AutoHealStateMachine.Decision
        /// Calls `guardState.beginRestart()`.
        var guardBeginRestart: () -> Bool
        /// Calls `guardState.endRestart()`.
        var guardEndRestart: () -> Void
        /// Calls `autoHeal.beginRestart()`.
        var autoHealBeginRestart: () -> Void
        /// Calls `autoHeal.endRestart(now:)`.
        var autoHealEndRestart: () -> Void
        /// Called when the probe outcome is `.healthy`.
        var onHealthy: () -> Void
        /// Called for `.markDegraded` OR before `.restart`.
        var onDegraded: () -> Void
        /// Called for `.markUnreachable`.
        var onUnreachable: () -> Void
        /// Called for `.restart` — must call stop + start in sequence.
        var restart: @MainActor () async -> Void
    }

    /// Runs the wake-recovery decision tree given a probe outcome.
    static func handle(
        outcome: ProbeOutcome,
        callbacks cb: Callbacks
    ) async {
        switch outcome {
        case .healthy:
            cb.recordHealthy()
            cb.onHealthy()
        case .unhealthy:
            let decision = cb.recordWakeFailure()
            switch decision {
            case .ignore: return
            case .markUnreachable: cb.onUnreachable()
            case .markDegraded: cb.onDegraded()
            case .restart:
                guard cb.guardBeginRestart() else { return }
                defer { cb.guardEndRestart() }
                cb.onDegraded()
                cb.autoHealBeginRestart()
                defer { cb.autoHealEndRestart() }
                await cb.restart()
            }
        }
    }
}
