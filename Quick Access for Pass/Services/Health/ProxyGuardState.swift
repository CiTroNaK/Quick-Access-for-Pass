import Foundation

/// Coordinator bookkeeping for two guards:
/// - `proxyGeneration`: bumped on each successful startProxy; used to drop
///   stale probe completions or stale client-loop failure signals from a
///   previous proxy incarnation.
/// - `isRestartInFlight`: short-circuits re-entrant restart attempts from
///   overlapping failure signals.
///
/// Extracted as a value type so both SSHProxyCoordinator and
/// RunProxyCoordinator can share identical logic and tests can cover it
/// without standing up the real coordinator's dependencies.
@MainActor
struct ProxyGuardState {
    private(set) var proxyGeneration: UInt64 = 0
    private(set) var isRestartInFlight: Bool = false

    /// Bump the generation counter and return the new value. Call on every
    /// successful startProxy — the returned generation is captured by health
    /// tasks and failureSignal closures so they can self-identify as stale.
    mutating func beginGeneration() -> UInt64 {
        proxyGeneration &+= 1
        return proxyGeneration
    }

    /// Returns true if an input tagged with `generation` is still valid
    /// (matches the current proxyGeneration). Probe completions and failure
    /// signals from prior proxy incarnations return false and should drop.
    func isCurrent(_ generation: UInt64) -> Bool {
        generation == proxyGeneration
    }

    /// Returns true if a restart can proceed. Sets `isRestartInFlight = true`
    /// as a side effect. Callers use `defer { endRestart() }` to clear.
    mutating func beginRestart() -> Bool {
        guard !isRestartInFlight else { return false }
        isRestartInFlight = true
        return true
    }

    mutating func endRestart() {
        isRestartInFlight = false
    }
}
