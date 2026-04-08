import Foundation

/// Pure-value state machine for proxy auto-healing. Matches spec section 5.3:
/// - Two-strike: two consecutive failure inputs trigger a restart.
/// - 120 s cooldown after any restart.
/// - Wake failures bypass two-strike but respect cooldown.
/// - Inputs during an in-flight restart are ignored.
nonisolated struct AutoHealStateMachine {
    static let cooldownSeconds: TimeInterval = 120

    private(set) var consecutiveFailures: Int = 0
    private(set) var lastRestartAt: Date?
    private(set) var isRestarting: Bool = false

    enum Decision: Sendable, Equatable {
        case ignore
        case markDegraded
        case restart
        case markUnreachable
    }

    mutating func recordFailure(now: Date) -> Decision {
        guard !isRestarting else { return .ignore }
        consecutiveFailures += 1
        if consecutiveFailures >= 2 {
            return isInCooldown(now: now) ? .markUnreachable : .restart
        }
        return .markDegraded
    }

    mutating func recordHealthy() {
        consecutiveFailures = 0
    }

    mutating func recordWakeFailure(now: Date) -> Decision {
        guard !isRestarting else { return .ignore }
        if isInCooldown(now: now) {
            return .markUnreachable
        }
        consecutiveFailures = max(consecutiveFailures, 2)
        return .restart
    }

    mutating func beginRestart() {
        isRestarting = true
    }

    mutating func endRestart(now: Date) {
        isRestarting = false
        lastRestartAt = now
        consecutiveFailures = 0
    }

    func isInCooldown(now: Date) -> Bool {
        guard let lastRestartAt else { return false }
        return now.timeIntervalSince(lastRestartAt) < Self.cooldownSeconds
    }
}
