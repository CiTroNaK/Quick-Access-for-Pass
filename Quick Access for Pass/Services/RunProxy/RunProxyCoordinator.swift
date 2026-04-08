import AppKit
import Darwin
import os

@MainActor
final class RunProxyCoordinator {
    let cliService: PassCLIService
    let databaseManager: DatabaseManager
    private let onError: ProxyErrorHandler
    let healthStore: ProxyHealthStore
    let passCLIStatusStore: PassCLIStatusStore
    private let keychainService: any BiometricAuthorizing
    private let defaults: UserDefaults
    private let authCallbacks: AuthDialogHelper.Callbacks
    var isAppLocked: @MainActor @Sendable () -> Bool = { false }
    var showLockedPanel: (@MainActor @Sendable () async -> Bool)?
    var setPendingLockContext: @MainActor @Sendable (PendingLockContext) -> UUID = { _ in UUID() }
    var clearPendingLockContext: @MainActor @Sendable (UUID) -> Void = { _ in }

    private(set) var proxy: RunProxy?
    private var authWindowController: RunAuthWindowController?
    var lastEnabled = false
    var resolvedSecrets: [String: (env: [String: String], resolvedAt: Date)] = [:]
    private var inFlightResolutions: [String: Task<[String: String], Error>] = [:]

    var autoHeal = AutoHealStateMachine()
    var guardState = ProxyGuardState()

    init(
        cliService: PassCLIService,
        databaseManager: DatabaseManager,
        onError: @escaping ProxyErrorHandler,
        healthStore: ProxyHealthStore,
        passCLIStatusStore: PassCLIStatusStore,
        keychainService: any BiometricAuthorizing,
        defaults: UserDefaults = .standard,
        authCallbacks: AuthDialogHelper.Callbacks = .noop
    ) {
        self.cliService = cliService
        self.databaseManager = databaseManager
        self.onError = onError
        self.healthStore = healthStore
        self.passCLIStatusStore = passCLIStatusStore
        self.keychainService = keychainService
        self.defaults = defaults
        self.authCallbacks = authCallbacks
    }

    // MARK: - Public

    func setup() {
        try? databaseManager.cleanupExpiredRunDecisions()

        authWindowController = RunAuthWindowController(databaseManager: databaseManager, keychainService: keychainService, callbacks: authCallbacks)

        lastEnabled = false

        Task {
            await reconcile()
        }
    }

    func reconcile() async {
        let enabled = defaults.bool(forKey: DefaultsKey.runProxyEnabled)
        guard enabled != lastEnabled else { return }
        lastEnabled = enabled

        if enabled {
            await startProxy()
        } else {
            await stopProxy()
            autoHeal = AutoHealStateMachine()
        }
    }

    func teardown() async {
        authWindowController?.cancelAll()
        if let proxy {
            await proxy.stop()
            self.proxy = nil
        }
        resolvedSecrets.removeAll(keepingCapacity: false)
        inFlightResolutions.removeAll(keepingCapacity: false)
        autoHeal = AutoHealStateMachine()
    }

    /// Synchronous shutdown for applicationWillTerminate. See SSHProxyCoordinator.shutdown.
    func shutdown() {
        authWindowController?.cancelAll()
        let listenPath = NSString(string: DefaultsKey.runProxySocketPath).expandingTildeInPath
        unlink(listenPath)
        proxy = nil
        resolvedSecrets.removeAll(keepingCapacity: false)
        inFlightResolutions.removeAll(keepingCapacity: false)
    }

    // MARK: - Private

    func startProxy() async {
        guard proxy == nil else { return }
        guard let authWindowController else { return }

        let listenPath = NSString(string: DefaultsKey.runProxySocketPath).expandingTildeInPath

        let authController = authWindowController
        let generation = guardState.beginGeneration()
        let newProxy = RunProxy(
            listenPath: listenPath,
            authorizationHandler: { [weak self] request, connection in
                guard let self else {
                    return RunProxyResponse(decision: .deny, env: nil)
                }
                return await self.authorizeRunRequest(request, connection: connection, authController: authController)
            },
            failureSignal: { [weak self] failure in
                guard RunProxyCoordinator.shouldSignalHealth(for: failure) else {
                    AppLogger.coordinator.debug("run client loop failure ignored for health \(String(describing: failure), privacy: .public)")
                    return
                }
                Task { @MainActor in
                    await self?.recordFailure(.clientLoop(failure), from: generation)
                }
            }
        )
        proxy = newProxy

        do {
            try await newProxy.start()
        } catch {
            onError(String(localized: "Failed to start run proxy: \(error.localizedDescription)"))
            proxy = nil
            return
        }

        updateRunHealth(.ok())
    }

    func stopProxy() async {
        if let proxy {
            await proxy.stop()
            self.proxy = nil
        }
        resolvedSecrets.removeAll(keepingCapacity: false)
        inFlightResolutions.removeAll(keepingCapacity: false)
        updateRunHealth(.disabled)
    }

    func setResolvedSecrets(_ env: [String: String], for slug: String) {
        resolvedSecrets[slug] = (env: env, resolvedAt: Date())
    }

    /// Dedupes concurrent resolutions of the same profile slug. Second and
    /// subsequent callers await the first in-flight Task.
    func resolveSecrets(
        forProfileSlug slug: String,
        mappings: [RunProfileEnvMapping]
    ) async throws -> [String: String] {
        if let existing = inFlightResolutions[slug] {
            return try await existing.value
        }
        let cli = cliService
        let task = Task<[String: String], Error> {
            try await RunSecretResolver.resolve(mappings: mappings, cliPath: cli.cliPath)
        }
        inFlightResolutions[slug] = task
        defer { inFlightResolutions[slug] = nil }
        return try await task.value
    }

    // MARK: - Health

    func updateRunHealth(_ new: ProxyHealthState) {
        guard healthStore.runHealth != new else { return }
        healthStore.runHealth = new
    }

    /// Applies a CLI health transition to `runHealth`. Called by
    /// `HealthCheckCoordinator.tickCLI()` after the coordinator diffs
    /// `previous != result` and detects an actual transition. Does NOT
    /// touch `PassCLIStatusStore` — the coordinator owns those writes.
    ///
    /// Mirrors the switch body of the legacy `runPassCLISanityCheck(runner:)`
    /// minus the three `passCLIStatusStore.{health, identity, version}` writes.
    func handleCLIHealthTransition(to health: PassCLIHealth) {
        switch health {
        case .ok:
            AppLogger.coordinator.notice("run CLI transition -> ok")
            switch healthStore.runHealth {
            case .unreachable(.passCLINotLoggedIn),
                 .unreachable(.passCLIFailed):
                updateRunHealth(.ok())
            default:
                break
            }
        case .notLoggedIn:
            AppLogger.coordinator.error("run CLI transition -> notLoggedIn")
            updateRunHealth(.unreachable(.passCLINotLoggedIn))
        case .notInstalled:
            AppLogger.coordinator.error("run CLI transition -> notInstalled")
            updateRunHealth(.unreachable(.passCLIFailed("pass-cli not found")))
        case .failed(let reason):
            AppLogger.coordinator.error("run CLI transition -> failed reason=\(reason, privacy: .public)")
            updateRunHealth(.unreachable(.passCLIFailed(reason)))
        }
    }

    /// Called by `HealthCheckCoordinator` on each Run probe tick with the result.
    /// Guards on `proxy != nil` for freshness (stale results from in-flight
    /// probes after a proxy restart are dropped) and delegates to
    /// `applyRunProbeResult(_:)` for the actual handling.
    ///
    /// The `proxy != nil` freshness discipline is load-bearing: it works only
    /// because tick bodies run on MainActor and the tick's own
    /// `guard !Task.isCancelled` check runs before this method is awaited.
    /// Moving this method or the tick body off MainActor silently re-introduces
    /// bug-A/D class regressions — see spec §EH3 and §EH6.
    func handleRunProbeResult(_ result: RunProbeResult) async {
        guard proxy != nil else { return }
        await applyRunProbeResult(result)
    }

    /// Test seam: executes the probe-result body without the `proxy != nil`
    /// guard. Coordinator tests call this directly to pin the
    /// `nextRunHealth(onHealthyProbeGiven:)` wiring without fabricating a real
    /// RunProxy. Production code calls `handleRunProbeResult(_:)` instead.
    func applyRunProbeResult(_ result: RunProbeResult) async {
        switch result {
        case .healthy:
            autoHeal.recordHealthy()
            updateRunHealth(Self.nextRunHealth(onHealthyProbeGiven: healthStore.runHealth))
        case .unreachable:
            await recordFailure(.probe)
        }
    }

    private enum RunFailureInput {
        case probe
        case clientLoop(RunClientLoopFailure)
    }

    private func reason(for input: RunFailureInput) -> ProxyHealthState.Reason {
        switch input {
        case .probe:       return .probeFailed
        case .clientLoop:  return .clientLoopFailure
        }
    }

    private func recordFailure(_ input: RunFailureInput = .probe, from generation: UInt64? = nil) async {
        if let generation, !guardState.isCurrent(generation) {
            AppLogger.coordinator.debug("run stale failureSignal dropped")
            return
        }
        let mappedReason = reason(for: input)
        let decision = autoHeal.recordFailure(now: Date())
        switch decision {
        case .ignore:
            AppLogger.coordinator.debug("run failure ignored")
        case .markDegraded:
            AppLogger.coordinator.notice("run marked degraded reason=\(String(describing: mappedReason), privacy: .public)")
            updateRunHealth(.degraded(mappedReason))
        case .restart:
            guard guardState.beginRestart() else {
                AppLogger.coordinator.debug("run restart already in flight, skipping")
                return
            }
            defer { guardState.endRestart() }
            AppLogger.coordinator.notice("run auto-heal restart reason=\(String(describing: mappedReason), privacy: .public)")
            updateRunHealth(.degraded(mappedReason))
            autoHeal.beginRestart()
            defer { autoHeal.endRestart(now: Date()) }
            await stopProxy()
            await startProxy()
        case .markUnreachable:
            AppLogger.coordinator.error("run unreachable (cooldown) reason=\(String(describing: mappedReason), privacy: .public)")
            updateRunHealth(.unreachable(.cooldown))
        }
    }

    /// Called by WakeObserver after the 2-second debounce.
    func handleWake() async {
        AppLogger.coordinator.notice("run handleWake")

        if proxy == nil {
            _ = await recoverProxyIfNeeded()
            return
        }

        let path = NSString(string: DefaultsKey.runProxySocketPath).expandingTildeInPath
        let result = await RunProxyProbe.ping(at: path)

        let outcome: WakeHandler.ProbeOutcome = (result == .healthy) ? .healthy : .unhealthy

        await WakeHandler.handle(
            outcome: outcome,
            callbacks: .init(
                recordHealthy: { [self] in autoHeal.recordHealthy() },
                recordWakeFailure: { [self] in autoHeal.recordWakeFailure(now: Date()) },
                guardBeginRestart: { [self] in guardState.beginRestart() },
                guardEndRestart: { [self] in guardState.endRestart() },
                autoHealBeginRestart: { [self] in autoHeal.beginRestart() },
                autoHealEndRestart: { [self] in autoHeal.endRestart(now: Date()) },
                onHealthy: { [self] in updateRunHealth(.ok()) },
                onDegraded: { [self] in updateRunHealth(.degraded(.probeFailed)) },
                onUnreachable: { [self] in updateRunHealth(.unreachable(.cooldown)) },
                restart: { [self] in
                    AppLogger.coordinator.notice("run wake restart triggered")
                    await stopProxy()
                    await startProxy()
                }
            )
        )
    }

}

extension RunProxyCoordinator {
    /// Returns `true` if a `RunClientLoopFailure` should drive proxy health.
    /// `.clientRequestReadFailed` is a client-side issue, not a proxy fault —
    /// the proxy's read call failed because the client never sent bytes, which
    /// can happen when a client is killed mid-flight. Treating it as a proxy
    /// health event caused false-positive "upstream error" alerts when the
    /// old connect-only probe self-triggered the read failure.
    nonisolated static func shouldSignalHealth(for failure: RunClientLoopFailure) -> Bool {
        switch failure {
        case .clientRequestReadFailed:
            return false
        case .authHandlerTimedOut, .clientResponseWriteFailed:
            return true
        }
    }

    /// Pure decision function: given the current runHealth, returns the
    /// runHealth that should be written when the socket-level probe reports
    /// healthy. The probe at `RunProxyProbe.ping` is deliberately socket-only
    /// and does **not** talk to pass-cli — it cannot tell "logged out" from
    /// "logged in". Login-derived unreachable states are owned by the CLI
    /// transition handler in `handleCLIHealthTransition(to:)`, which is
    /// driven by `HealthCheckCoordinator.tickCLI()`; a healthy probe must
    /// not overwrite them.
    nonisolated static func nextRunHealth(
        onHealthyProbeGiven current: ProxyHealthState
    ) -> ProxyHealthState {
        switch current {
        case .unreachable(.passCLINotLoggedIn),
             .unreachable(.passCLIFailed):
            return current
        default:
            return .ok()
        }
    }
}
