import Foundation

extension AppDelegate {
    func makeSSHCoordinator(authCallbacks: AuthDialogHelper.Callbacks) -> SSHProxyCoordinator {
        let coordinator = SSHProxyCoordinator(
            cliService: cliService!,
            databaseManager: databaseManager!,
            onError: { [weak self] message in self?.viewModel?.errorMessage = message },
            healthStore: healthStore,
            keychainService: keychainService!,
            passCLIStatusStore: passCLIStatusStore,
            authCallbacks: authCallbacks
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
