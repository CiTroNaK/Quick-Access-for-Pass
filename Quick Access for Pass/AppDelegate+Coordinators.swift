import Foundation

@MainActor
private struct AppPassCLIHealthRefresher: PassCLIHealthRefreshing {
    weak var appDelegate: AppDelegate?

    func refreshPassCLIHealth() async -> PassCLIHealth {
        await appDelegate?.healthCoordinator?.refreshPassCLI()
            ?? .failed(reason: "Health refresh unavailable")
    }
}

extension AppDelegate {
    func setupCoordinators() {
        notificationRouter = UserNotificationRouter()

        syncCoordinator = SyncCoordinator(cliService: cliService!, databaseManager: databaseManager!, viewModel: viewModel!)
        syncCoordinator?.start()

        if let cliService {
            let loginCoordinator = PassCLILoginCoordinator(
                cliService: cliService,
                healthRefresher: AppPassCLIHealthRefresher(appDelegate: self),
                syncTrigger: { [weak self] in self?.syncCoordinator?.refreshNow() },
                resultHandler: { [weak self] result in self?.passCLILoginNotifier?.handleLoginResult(result) }
            )
            passCLILoginCoordinator = loginCoordinator

            let loginNotifier = PassCLILoginNotifier(
                notificationRouter: notificationRouter,
                startLogin: { [weak loginCoordinator] in loginCoordinator?.startLogin() }
            )
            loginNotifier.requestAuthorizationIfNeeded()
            passCLILoginNotifier = loginNotifier
        }

        let authCallbacks = AuthDialogHelper.Callbacks(
            onAuthSuccess: { [weak self] in self?.resetAuthTimestamp() },
            onBiometryLockout: { [weak self] in self?.forceLock() }
        )

        sshCoordinator = makeSSHCoordinator(authCallbacks: authCallbacks)
        wireLockClosures(on: sshCoordinator)

        runCoordinator = makeRunCoordinator(authCallbacks: authCallbacks)
        wireLockClosures(on: runCoordinator)

        if let cliService, let runCoordinator, let sshCoordinator {
            healthCoordinator = HealthCheckCoordinator(
                cliStore: passCLIStatusStore,
                cliService: cliService,
                cliChecker: LivePassCLIHealthChecker(),
                runChecker: LiveRunProbeChecker(),
                sshChecker: LiveSSHProbeChecker(),
                runCoordinator: runCoordinator,
                sshCoordinator: sshCoordinator,
                passCLITransitionHandler: passCLILoginNotifier
            )
        }
    }

    func setupWakeObserver() {
        wakeObserver = WakeObserver { [weak self] in
            await self?.healthCoordinator?.handleSystemWake()
        }
        wakeObserver?.start()
    }

    func setupSystemLockObserver() {
        systemLockObserver = SystemLockObserver { [weak self] in
            self?.handleSystemLockEvent()
        }
        systemLockObserver?.start()
    }

    func runLaunchTimeSanityCheck() {
        Task { [weak self] in
            await self?.healthCoordinator?.start()
        }
    }

    func makeSSHCoordinator(authCallbacks: AuthDialogHelper.Callbacks) -> SSHProxyCoordinator {
        let coordinator = SSHProxyCoordinator(
            cliService: cliService!,
            databaseManager: databaseManager!,
            onError: { [weak self] message in self?.viewModel?.errorMessage = message },
            healthStore: healthStore,
            keychainService: keychainService!,
            passCLIStatusStore: passCLIStatusStore,
            authCallbacks: authCallbacks,
            notificationRouter: notificationRouter
        )
        coordinator.setup()
        return coordinator
    }

    func makeRunCoordinator(authCallbacks: AuthDialogHelper.Callbacks) -> RunProxyCoordinator {
        let coordinator = RunProxyCoordinator(
            cliService: cliService!,
            databaseManager: databaseManager!,
            onError: { [weak self] message in self?.viewModel?.errorMessage = message },
            healthStore: healthStore,
            passCLIStatusStore: passCLIStatusStore,
            keychainService: keychainService!,
            authCallbacks: authCallbacks
        )
        coordinator.setup()
        return coordinator
    }

    /// Wires the four lock-lifecycle closures onto an SSH coordinator.
    /// `?? UUID()` is unreachable in practice: AppDelegate lives for the
    /// whole process. It satisfies the non-optional return type when the
    /// compiler cannot prove liveness through `[weak self]`.
    func wireLockClosures(on coordinator: SSHProxyCoordinator?) {
        coordinator?.isAppLocked = { [weak self] in self?.isLocked ?? false }
        coordinator?.showLockedPanel = { [weak self] in
            await self?.showPanelAndWaitForUnlock() ?? false
        }
        coordinator?.setPendingLockContext = { [weak self] context in
            self?.setPendingLockContext(context) ?? UUID()
        }
        coordinator?.clearPendingLockContext = { [weak self] token in
            self?.clearPendingLockContext(token: token)
        }
    }

    func wireLockClosures(on coordinator: RunProxyCoordinator?) {
        coordinator?.isAppLocked = { [weak self] in self?.isLocked ?? false }
        coordinator?.showLockedPanel = { [weak self] in
            await self?.showPanelAndWaitForUnlock() ?? false
        }
        coordinator?.setPendingLockContext = { [weak self] context in
            self?.setPendingLockContext(context) ?? UUID()
        }
        coordinator?.clearPendingLockContext = { [weak self] token in
            self?.clearPendingLockContext(token: token)
        }
    }
}
