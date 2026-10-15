import Foundation

@MainActor
extension AppDelegate {
    /// Routes every user-initiated browser login through explicit session-repair consent.
    func requestPassCLILogin() {
        passCLILoginCoordinator?.requestLogin(
            confirmSessionReset: PassCLISessionRepairConfirmation.confirm
        )
    }

    /// Publishes an unreadable browser-login session through the shared health/recovery path.
    func handlePassCLIBrowserLoginResult(_ result: PassCLILoginResult) {
        passCLILoginNotifier?.handleLoginResult(result)
        guard result == .localSessionUnreadable else { return }
        Task { @MainActor [weak self] in
            guard self?.passCLILoginCoordinator?.state == .localSessionUnreadable else { return }
            await self?.healthCoordinator?.reportAuthenticationFailure(health: .localSessionUnreadable)
        }
    }
}
