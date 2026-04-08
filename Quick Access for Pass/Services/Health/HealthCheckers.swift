// Quick Access for Pass/Services/Health/HealthCheckers.swift
import Foundation

/// Result type returned by `PassCLIHealthChecking.check(cliPath:)`. Carries
/// the three values the coordinator needs to write `PassCLIStatusStore` from
/// a single protocol call, so tests can fake all three without hitting real
/// subprocesses for identity/version fetches.
nonisolated struct PassCLIProbeOutcome: Sendable, Equatable {
    let health: PassCLIHealth
    let identity: PassCLIIdentity?
    let version: String?
}

/// Probes pass-cli login state and (on `.ok`) fetches identity and version.
/// Sole source of CLI-derived data for `HealthCheckCoordinator.tickCLI()`.
protocol PassCLIHealthChecking: Sendable {
    func check(cliPath: String) async -> PassCLIProbeOutcome
}

/// Probes the Run proxy listen socket (round-trip ping). Does not talk to
/// pass-cli — socket-level only. See `RunProxyProbe.ping` for the contract.
protocol RunProbeChecking: Sendable {
    func check(socketPath: String) async -> RunProbeResult
}

/// Probes the SSH proxy listen socket end-to-end by issuing a REQUEST_IDENTITIES
/// through the proxy to the upstream pass-cli daemon. See
/// `SSHProxyProbe.listIdentities` for the contract.
protocol SSHProbeChecking: Sendable {
    func check(listenPath: String) async -> SSHProbeResult
}

// MARK: - Production checkers

nonisolated struct LivePassCLIHealthChecker: PassCLIHealthChecking {
    let runner: CLIRunning

    init(runner: CLIRunning = LiveCLIRunner()) {
        self.runner = runner
    }

    func check(cliPath: String) async -> PassCLIProbeOutcome {
        let health = await PassCLISanityCheck.checkLoginStatus(
            cliPath: cliPath, runner: runner
        )
        guard health == .ok else {
            return PassCLIProbeOutcome(health: health, identity: nil, version: nil)
        }
        async let fetchedIdentity = PassCLISanityCheck.fetchIdentity(
            cliPath: cliPath, runner: runner
        )
        async let fetchedVersion = PassCLISanityCheck.fetchVersion(
            cliPath: cliPath, runner: runner
        )
        return PassCLIProbeOutcome(
            health: health,
            identity: await fetchedIdentity,
            version: await fetchedVersion
        )
    }
}

nonisolated struct LiveRunProbeChecker: RunProbeChecking {
    func check(socketPath: String) async -> RunProbeResult {
        await RunProxyProbe.ping(at: socketPath)
    }
}

nonisolated struct LiveSSHProbeChecker: SSHProbeChecking {
    func check(listenPath: String) async -> SSHProbeResult {
        await SSHProxyProbe.listIdentities(at: listenPath)
    }
}
