import Foundation
import os

@MainActor
extension SSHProxyCoordinator {
    func updateSSHHealth(_ new: ProxyHealthState) {
        guard healthStore.sshHealth != new else { return }
        healthStore.sshHealth = new
    }

    /// Applies a CLI health transition to `sshHealth`. Called by
    /// `HealthCheckCoordinator.tickCLI()` after the coordinator diffs
    /// `previous != result` and detects an actual transition. On `.ok`,
    /// delegates to `handleCLIHealthRecovered()` which may trigger a real
    /// proxy restart via `recoverProxyIfNeeded()` when the proxy is nil.
    ///
    /// Mirrors the switch body of the legacy `handleCLIHealthChange(_:)`.
    func handleCLIHealthTransition(to health: PassCLIHealth) async {
        guard lastEnabled else { return }
        switch health {
        case .ok:
            await handleCLIHealthRecovered()
        case .notLoggedIn:
            updateSSHHealth(.unreachable(.passCLINotLoggedIn))
        case .notInstalled:
            updateSSHHealth(.unreachable(.passCLIFailed("pass-cli not found")))
        case .failed(let reason):
            updateSSHHealth(.unreachable(.passCLIFailed(reason)))
        }
    }

    /// Branching behavior when pass-cli reports healthy:
    /// - `proxy != nil`: the probe is actively running and will keep us
    ///   honest within 30 s. Flip the cosmetic label immediately so the
    ///   user isn't looking at a stale "pass-cli error" row.
    /// - `proxy == nil`: the proxy is not running — either an earlier
    ///   auto-heal restart bailed out, or `startProxy()` itself failed
    ///   cleanly along one of its three failure paths. Either way the
    ///   listen socket is gone. Drive a real restart — **do not** flip
    ///   the label cosmetically, because doing so would put the menu
    ///   bar into a lying state ("OK" with no socket).
    func handleCLIHealthRecovered() async {
        if proxy != nil {
            if Self.shouldFlipSSHHealthLabelOnCLIRecovery(healthStore.sshHealth) {
                updateSSHHealth(.ok())
            }
            return
        }
        await recoverProxyIfNeeded()
    }

    /// Called by `HealthCheckCoordinator` on each SSH probe tick with the result.
    /// Guards on `proxy != nil` for freshness and delegates to
    /// `applySSHProbeResult(_:)` for the actual handling.
    ///
    /// The `proxy != nil` freshness discipline is load-bearing — see the
    /// matching doc comment on `RunProxyCoordinator.handleRunProbeResult`.
    func handleSSHProbeResult(_ result: SSHProbeResult) async {
        guard proxy != nil else { return }
        await applySSHProbeResult(result)
    }

    /// Test seam: executes the probe-result body without the `proxy != nil`
    /// guard. Coordinator tests (specifically test 15 "EH3 race") call this
    /// directly to pin the `nextSSHHealth(onHealthyProbeGiven:withKeyCount:)`
    /// wiring without fabricating a real SSHAgentProxy. Production code calls
    /// `handleSSHProbeResult(_:)` instead.
    func applySSHProbeResult(_ result: SSHProbeResult) async {
        switch result {
        case .healthy(let count):
            autoHeal.recordHealthy()
            updateSSHHealth(Self.nextSSHHealth(
                onHealthyProbeGiven: healthStore.sshHealth,
                withKeyCount: count
            ))
        case .emptyIdentities:
            await recordFailure(.probeEmptyIdentities)
        case .unreachable(let failure):
            await recordFailure(.probeUnreachable(failure))
        }
    }

    func recordFailure(_ input: SSHFailureInput, from generation: UInt64? = nil) async {
        if let generation, !guardState.isCurrent(generation) {
            AppLogger.coordinator.debug("ssh stale failureSignal dropped")
            return
        }
        let mappedReason = input.healthReason
        let decision = autoHeal.recordFailure(now: Date())

        switch decision {
        case .ignore:
            AppLogger.coordinator.debug("ssh failure ignored (restart in progress)")
        case .markDegraded:
            AppLogger.coordinator.notice("ssh degraded reason=\(String(describing: mappedReason), privacy: .public)")
            updateSSHHealth(.degraded(mappedReason))
        case .restart:
            guard guardState.beginRestart() else {
                AppLogger.coordinator.debug("ssh restart already in flight, skipping")
                return
            }
            defer { guardState.endRestart() }
            AppLogger.coordinator.notice("ssh auto-heal restart reason=\(String(describing: mappedReason), privacy: .public)")
            updateSSHHealth(.degraded(mappedReason))
            autoHeal.beginRestart()
            defer { autoHeal.endRestart(now: Date()) }
            await stopProxy()
            await startProxy()
        case .markUnreachable:
            AppLogger.coordinator.error("ssh unreachable (cooldown) reason=\(String(describing: mappedReason), privacy: .public)")
            updateSSHHealth(.unreachable(.cooldown))
        }
    }
}

extension SSHProxyCoordinator {
    /// Pure decision function for the "CLI recovered to .ok" label-flip
    /// path. Returns `true` when the current sshHealth is a pass-cli
    /// login-derived unreachable state that we should optimistically flip
    /// to `.ok()` — the probe will correct it within 30 s if that turns
    /// out to be wrong.
    nonisolated static func shouldFlipSSHHealthLabelOnCLIRecovery(
        _ current: ProxyHealthState
    ) -> Bool {
        switch current {
        case .unreachable(.passCLINotLoggedIn),
             .unreachable(.passCLIFailed):
            return true
        default:
            return false
        }
    }

    /// Returns the `sshHealth` that should be written when the SSH probe
    /// reports healthy. Preserves login-derived unreachable states — only
    /// the sanity check (via `handleCLIHealthTransition(to:)`) may clear
    /// those, never a healthy probe. Mirrors
    /// `RunProxyCoordinator.nextRunHealth(onHealthyProbeGiven:)`.
    nonisolated static func nextSSHHealth(
        onHealthyProbeGiven current: ProxyHealthState,
        withKeyCount keyCount: Int
    ) -> ProxyHealthState {
        switch current {
        case .unreachable(.passCLINotLoggedIn),
             .unreachable(.passCLIFailed):
            return current
        default:
            return .ok(detail: "\(keyCount) key\(keyCount == 1 ? "" : "s")")
        }
    }
}
