// Quick Access for Pass/Services/Health/HealthCheckCoordinator.swift
import Foundation
import Observation

/// Coordinates scheduling of pass-cli, Run proxy, and SSH proxy health checks.
/// Gates SSH and Run probes on `PassCLIStatusStore.health == .ok` so no probe
/// work runs while pass-cli is logged out. Sole writer of `PassCLIStatusStore`.
///
/// This type is the single owner of "when a health check runs." Probe
/// classification logic lives in the `*Checker` types; auto-heal and lifecycle
/// stay in the proxy coordinators.
///
/// ## Invariant: one-directional dependency
///
/// This coordinator holds strong references to `RunProxyCoordinator` and
/// `SSHProxyCoordinator`. **Proxy coordinators MUST NOT hold a reference
/// back to this type.** The dependency is one-directional: coordinator →
/// proxy. External refresh triggers route through `AppDelegate`, never
/// through a back-reference. No retain cycle exists because `AppDelegate`
/// owns all three and explicitly calls `cancel()` at terminate.
@MainActor
@Observable
final class HealthCheckCoordinator {
    static let cliIntervalSeconds: Int = 30
    static let runIntervalSeconds: Int = 30
    static let sshIntervalSeconds: Int = 30

    let cliStore: PassCLIStatusStore
    let cliService: PassCLIService
    let cliChecker: any PassCLIHealthChecking
    let runChecker: any RunProbeChecking
    let sshChecker: any SSHProbeChecking

    // Strong refs: AppDelegate owns all three. The one-directional invariant
    // above prevents a retain cycle. `weak` would silently drop dispatches if
    // the invariant is ever violated, which is worse than a loud crash.
    let runCoordinator: any RunProxyDispatching
    let sshCoordinator: any SSHProxyDispatching

    private var cliTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var sshTask: Task<Void, Never>?
    /// Reentrancy guard for `start()`. Prevents a second `start()` call
    /// during the first call's `await tickCLI()` from slipping past the
    /// `cliTask == nil` check and spawning duplicate task loops (EH7).
    private var isStarting: Bool = false

    init(
        cliStore: PassCLIStatusStore,
        cliService: PassCLIService,
        cliChecker: any PassCLIHealthChecking,
        runChecker: any RunProbeChecking,
        sshChecker: any SSHProbeChecking,
        runCoordinator: any RunProxyDispatching,
        sshCoordinator: any SSHProxyDispatching
    ) {
        self.cliStore = cliStore
        self.cliService = cliService
        self.cliChecker = cliChecker
        self.runChecker = runChecker
        self.sshChecker = sshChecker
        self.runCoordinator = runCoordinator
        self.sshCoordinator = sshCoordinator
    }

    // MARK: - Public API

    /// Runs an initial synchronous CLI probe (seeding `cliStore.health`
    /// before the SSH/Run gates evaluate), then spawns the three tick loops.
    ///
    /// Reentrancy-safe: guarded by both `cliTask == nil` AND an `isStarting`
    /// sentinel so a second `start()` call arriving during the initial
    /// `await tickCLI()` cannot slip through (EH7).
    func start() async {
        guard cliTask == nil, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        await tickCLI()
        cliTask = runCLITickLoop(fireImmediately: false)
        runTask = runRunTickLoop(fireImmediately: true)
        sshTask = runSSHTickLoop(fireImmediately: true)
    }

    /// Cancels all three tick tasks. Does NOT await in-flight probe completion —
    /// in-flight probes continue to their timeout ceiling in the background
    /// (up to 5 s for CLI, 2 s each for Run / SSH). Callers that need
    /// quiesce-to-idle must use a separate mechanism.
    func cancel() {
        cliTask?.cancel()
        runTask?.cancel()
        sshTask?.cancel()
        cliTask = nil
        runTask = nil
        sshTask = nil
    }

    /// Fires one tick of each loop out-of-band, without cancelling or
    /// respawning the task loops. Used by Settings-window-key and menu-bar
    /// "Refresh Now" triggers. The running tick loops continue on their own
    /// schedule — this just adds a single extra probe cycle right now.
    ///
    /// Unlike the original "cancel and respawn" design, this shape avoids the
    /// race where an in-flight old tick could dispatch stale transitions after
    /// the new task was spawned.
    func refreshAll() async {
        await tickCLI()
        await tickRun()
        await tickSSH()
    }

    /// Wake-from-sleep orchestrator. Fires `refreshAll()` then calls each
    /// proxy coordinator's `handleWake()` sequentially. Distinct name from
    /// per-proxy `handleWake()` to avoid shadowing. Sequential rather than
    /// concurrent because MainActor serializes everything anyway; a
    /// `withTaskGroup` fan-out would buy nothing.
    ///
    /// See spec §EH8 for the concurrent-recovery-path idempotence analysis.
    func handleSystemWake() async {
        await refreshAll()
        await runCoordinator.handleWake()
        await sshCoordinator.handleWake()
    }

    // MARK: - Test seams (internal)

    /// Executes one CLI tick body: probe → write store → dispatch transition.
    /// Called by the production tick loop AND directly by tests.
    /// - Note: Test seam — do not inline into the loop factory.
    func tickCLI() async {
        let outcome = await cliChecker.check(cliPath: cliService.cliPath)
        guard !Task.isCancelled else { return }

        let previous = cliStore.health
        cliStore.health = outcome.health
        cliStore.identity = outcome.identity
        cliStore.version = outcome.version

        guard !Task.isCancelled else { return }
        guard previous != outcome.health else { return }
        runCoordinator.handleCLIHealthTransition(to: outcome.health)
        await sshCoordinator.handleCLIHealthTransition(to: outcome.health)
    }

    /// Executes one Run probe tick body. Gated on CLI health and proxy liveness.
    /// - Note: Test seam — do not inline into the loop factory.
    func tickRun() async {
        guard cliStore.health == .ok else { return }
        guard runCoordinator.lastEnabled, runCoordinator.isProxyLive else { return }

        let path = NSString(string: DefaultsKey.runProxySocketPath).expandingTildeInPath
        let result = await runChecker.check(socketPath: path)
        guard !Task.isCancelled else { return }

        await runCoordinator.handleRunProbeResult(result)
    }

    /// Executes one SSH probe tick body. Gated on CLI health and proxy liveness.
    /// - Note: Test seam — do not inline into the loop factory.
    func tickSSH() async {
        guard cliStore.health == .ok else { return }
        guard sshCoordinator.lastEnabled, sshCoordinator.isProxyLive else { return }

        let path = NSString(string: SSHAgentConstants.defaultProxySocketPath).expandingTildeInPath
        let result = await sshChecker.check(listenPath: path)
        guard !Task.isCancelled else { return }

        await sshCoordinator.handleSSHProbeResult(result)
    }

    // MARK: - Task loop factories (private)

    private func runCLITickLoop(fireImmediately: Bool) -> Task<Void, Never> {
        Task { [self] in
            // Strong `self` capture is intentional: AppDelegate owns this
            // coordinator for the app's lifetime and explicitly calls
            // `cancel()` at terminate. A `[weak self]` capture would be
            // misleading because `guard let self` at the top would upgrade
            // it back to strong for the entire while-loop duration anyway.
            if !fireImmediately {
                try? await Task.sleep(for: .seconds(Self.cliIntervalSeconds))
            }
            while !Task.isCancelled {
                await self.tickCLI()
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(Self.cliIntervalSeconds))
            }
        }
    }

    private func runRunTickLoop(fireImmediately: Bool) -> Task<Void, Never> {
        Task { [self] in
            if !fireImmediately {
                try? await Task.sleep(for: .seconds(Self.runIntervalSeconds))
            }
            while !Task.isCancelled {
                await self.tickRun()
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(Self.runIntervalSeconds))
            }
        }
    }

    private func runSSHTickLoop(fireImmediately: Bool) -> Task<Void, Never> {
        Task { [self] in
            if !fireImmediately {
                try? await Task.sleep(for: .seconds(Self.sshIntervalSeconds))
            }
            while !Task.isCancelled {
                await self.tickSSH()
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(Self.sshIntervalSeconds))
            }
        }
    }

    #if DEBUG
    /// Test accessors for the private task properties. Required because
    /// `@testable import` does not expose `private` members.
    var debugCLITaskIsLive: Bool { cliTask != nil }
    var debugRunTaskIsLive: Bool { runTask != nil }
    var debugSSHTaskIsLive: Bool { sshTask != nil }
    #endif
}
