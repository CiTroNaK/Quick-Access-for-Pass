import AppKit
import Darwin
import os

/// Callback invoked by proxy coordinators to surface user-facing
/// error messages to the presentation layer. Injected at coordinator
/// construction so coordinators never hold a reference to the
/// ViewModel directly. The callback is `@MainActor` because it
/// mutates MainActor-isolated state (`QuickAccessViewModel.errorMessage`).
/// `@MainActor`-isolated closures are implicitly `Sendable`, so no
/// explicit `@Sendable` annotation is needed.
typealias ProxyErrorHandler = @MainActor (String) -> Void

@MainActor
final class SSHProxyCoordinator {
    private let cliService: PassCLIService
    private let databaseManager: DatabaseManager
    private let onError: ProxyErrorHandler
    let healthStore: ProxyHealthStore
    private let keychainService: any BiometricAuthorizing
    let passCLIStatusStore: PassCLIStatusStore
    private let authCallbacks: AuthDialogHelper.Callbacks
    let defaults: UserDefaults
    var isAppLocked: @MainActor @Sendable () -> Bool = { false }
    var showLockedPanel: (@MainActor @Sendable () async -> Bool)?
    var setPendingLockContext: @MainActor @Sendable (PendingLockContext) -> UUID = { _ in UUID() }
    var clearPendingLockContext: @MainActor @Sendable (UUID) -> Void = { _ in }

    private(set) var proxy: SSHAgentProxy?
    private(set) var daemonManager: SSHAgentDaemonManager?
    var authWindowController: SSHAuthWindowController?
    private var batchModeNotifier: SSHBatchModeNotifier?
    var lastEnabled = false
    private var lastVaultFilter: Set<String> = []
    var lastCliPath: String?

    var autoHeal = AutoHealStateMachine()
    var guardState = ProxyGuardState()

    init(
        cliService: PassCLIService,
        databaseManager: DatabaseManager,
        onError: @escaping ProxyErrorHandler,
        healthStore: ProxyHealthStore,
        keychainService: any BiometricAuthorizing,
        passCLIStatusStore: PassCLIStatusStore,
        defaults: UserDefaults = .standard,
        authCallbacks: AuthDialogHelper.Callbacks = .noop
    ) {
        self.cliService = cliService
        self.databaseManager = databaseManager
        self.onError = onError
        self.healthStore = healthStore
        self.keychainService = keychainService
        self.passCLIStatusStore = passCLIStatusStore
        self.defaults = defaults
        self.authCallbacks = authCallbacks
    }

    // MARK: - Public

    func setup() {
        // Cleanup expired decisions on launch
        try? databaseManager.cleanupExpiredDecisions()

        authWindowController = SSHAuthWindowController(databaseManager: databaseManager, keychainService: keychainService, callbacks: authCallbacks)

        let notifier = SSHBatchModeNotifier(databaseManager: databaseManager)
        notifier.requestAuthorizationIfNeeded()
        authWindowController?.batchModeNotifier = notifier
        batchModeNotifier = notifier

        // Snapshot current state so reconcile detects the initial "change"
        lastEnabled = false
        lastVaultFilter = []
        lastCliPath = nil

        // Start if already enabled
        Task {
            await reconcile()
        }
    }

    func reconcile() async {
        let enabled = defaults.bool(forKey: DefaultsKey.sshProxyEnabled)
        let vaultFilterJSON = defaults.string(forKey: DefaultsKey.sshVaultFilter) ?? "[]"
        let vaultFilter = Set((try? JSONDecoder().decode([String].self, from: Data(vaultFilterJSON.utf8))) ?? [])
        let cliPath = cliService.cliPath

        let enabledChanged = enabled != lastEnabled
        let vaultFilterChanged = vaultFilter != lastVaultFilter
        let cliPathChanged = cliPath != lastCliPath

        guard enabledChanged || vaultFilterChanged || cliPathChanged else { return }

        lastEnabled = enabled
        lastVaultFilter = vaultFilter
        lastCliPath = cliPath

        if enabled {
            // Stop the running daemon when its dependencies (vault filter or
            // cliPath) change. The daemon child process was spawned with the
            // old values; startProxy() will respawn with the fresh ones.
            if (vaultFilterChanged || cliPathChanged) && proxy != nil {
                await stopProxy()
            }
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
        if let daemonManager {
            await daemonManager.stopDaemon()
            self.daemonManager = nil
        }
        SSHKeyNameCache.shared.clear()
        autoHeal = AutoHealStateMachine()
    }

    /// Synchronous shutdown for applicationWillTerminate. Cancels MainActor-bound
    /// resources and unlinks the listen socket. Does not stop the actor proxy —
    /// Task.detached from an application-will-terminate delegate does not reliably
    /// run before exit(). The OS closes file descriptors on process termination.
    func shutdown() {
        authWindowController?.cancelAll()
        let listenPath = NSString(string: SSHAgentConstants.defaultProxySocketPath).expandingTildeInPath
        unlink(listenPath)
        proxy = nil
        daemonManager = nil
        SSHKeyNameCache.shared.clear()
    }

    // MARK: - Private

    // sequential setup with multiple error paths
    func startProxy() async {
        guard proxy == nil else { return }
        guard let authWindowController else { return }

        let cliPath = cliService.cliPath
        let upstreamOverride = defaults.string(forKey: DefaultsKey.sshUpstreamSocketPath)
        let upstreamPath: String
        if let override = upstreamOverride, !override.isEmpty {
            upstreamPath = NSString(string: override).expandingTildeInPath
        } else {
            upstreamPath = NSString(string: SSHAgentConstants.defaultUpstreamSocketPath).expandingTildeInPath
        }
        let listenPath = NSString(string: SSHAgentConstants.defaultProxySocketPath).expandingTildeInPath

        // Start Pass CLI daemon
        let daemon = SSHAgentDaemonManager(cliPath: cliPath, socketPath: upstreamPath)
        daemonManager = daemon

        do {
            try await daemon.startDaemon(vaultNames: currentVaultFilter())
        } catch let error as CLIError where error.isAuthError {
            onError(String(localized: "SSH agent requires login. Run: pass-cli login"))
            await resetStartupState()
            return
        } catch {
            onError(String(localized: "Failed to start SSH agent: \(error.localizedDescription)"))
            await resetStartupState()
            return
        }

        // Wait for upstream socket to appear (daemon takes a moment to create it)
        let waitedOk = await waitForSocket(path: upstreamPath, timeout: 5)
        if !waitedOk {
            onError(String(localized: "SSH agent daemon started but socket not found at \(upstreamPath)"))
            await resetStartupState()
            return
        }

        // Start proxy
        let authController = authWindowController
        let generation = guardState.beginGeneration()
        let newProxy = SSHAgentProxy(
            listenPath: listenPath,
            upstreamPath: upstreamPath,
            authorizationHandler: { [weak self] keyBlob, connection in
                guard let self else { return .deny }
                return await self.authorizeProxyRequest(
                    keyBlob: keyBlob,
                    connection: connection,
                    authController: authController
                )
            },
            failureSignal: { [weak self] failure in
                Task { @MainActor in
                    await self?.recordFailure(.clientLoop(failure), from: generation)
                }
            }
        )
        proxy = newProxy

        do {
            try await newProxy.start()
        } catch {
            onError(String(localized: "Failed to start SSH proxy: \(error.localizedDescription)"))
            await resetStartupState()
            return
        }

        updateSSHHealth(.ok())
    }

    /// Restores `startProxy()`'s invariants after a failure along any of
    /// its three failure paths. After this returns, `proxy == nil` and
    /// `daemonManager == nil`, and any daemon this coordinator started has
    /// been asked to stop. Safe to call even when neither field was ever
    /// assigned — `stopDaemon()` guards on `daemonStartedByUs`, and `nil`-
    /// assignment on an already-`nil` property is a no-op.
    ///
    /// The snapshot-then-nil-then-await ordering is load-bearing: nil
    /// assignments run synchronously on the MainActor before any suspension,
    /// so if a concurrent `startProxy()` interleaves during `stopDaemon()`'s
    /// suspension and assigns new `proxy` / `daemonManager` values, this
    /// helper will not clobber them on resumption.
    private func resetStartupState() async {
        let managerToStop = daemonManager
        proxy = nil
        daemonManager = nil
        await managerToStop?.stopDaemon()
    }

    func stopProxy() async {
        if let proxy {
            await proxy.stop()
            self.proxy = nil
        }
        if let daemonManager {
            await daemonManager.stopDaemon()
            self.daemonManager = nil
        }
        updateSSHHealth(.disabled)
    }

    /// Restarts the SSH proxy if it is enabled but not currently running.
    ///
    /// Used by the CLI-login recovery path to heal a proxy that died when
    /// an earlier auto-heal restart bailed out (typically because pass-cli
    /// was logged out and `daemon.startDaemon()` threw). Safe to call
    /// concurrently with another restart attempt — the `ProxyGuardState`
    /// check returns `false` immediately if a restart is already in flight.
    ///
    /// - Returns: `true` if a restart was attempted (success or failure),
    ///   `false` if skipped (SSH disabled, proxy already running, or a
    ///   concurrent restart is in flight).
    @discardableResult
    func recoverProxyIfNeeded() async -> Bool {
        guard lastEnabled else { return false }
        guard proxy == nil else { return false }
        guard guardState.beginRestart() else {
            AppLogger.coordinator.debug("ssh recoverProxyIfNeeded: restart already in flight")
            return false
        }
        defer { guardState.endRestart() }
        AppLogger.coordinator.notice("ssh recoverProxyIfNeeded: proxy nil, restarting")
        autoHeal = AutoHealStateMachine()
        await startProxy()
        return true
    }

}
