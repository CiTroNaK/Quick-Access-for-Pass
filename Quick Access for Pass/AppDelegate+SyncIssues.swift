import AppKit

@MainActor
extension AppDelegate {
    func showSyncIssueWindow() {
        syncIssueWindowController?.show(
            presentation: viewModel?.currentSyncDiagnosticsPresentation,
            relativeTo: panelController?.windowForPresentation
        )
    }

    func syncIssueDidChange(_ presentation: QuickAccessSyncIssuePresentation?) {
        syncIssueWindowController?.syncIssueDidChange(presentation)
    }

    func resolveSyncIssueWindowIfVisible() {
        syncIssueDidChange(nil)
    }

    func showLoginRequiredSyncIssue() {
        viewModel?.errorMessage = nil
        viewModel?.syncProgress = nil
        if viewModel?.syncError?.action != .updatePAT {
            viewModel?.syncError = .loginRequired()
        }
        resolveSyncIssueWindowIfVisible()
    }

    func showPATAutoLoginSyncProgress() {
        viewModel?.errorMessage = nil
        viewModel?.syncError = nil
        viewModel?.syncProgress = .loggingInWithSavedPAT()
        resolveSyncIssueWindowIfVisible()
    }

    func showInvalidPATSyncIssue(userFacingMessage: String) {
        showPATLoginFailureSyncIssue(userFacingMessage: userFacingMessage)
    }

    /// Settles automatic PAT progress without presenting browser sign-in.
    func showPATLoginFailureSyncIssue(userFacingMessage: String) {
        viewModel?.errorMessage = nil
        viewModel?.syncProgress = nil
        viewModel?.syncError = .patLoginFailed(userFacingMessage: userFacingMessage)
        resolveSyncIssueWindowIfVisible()
    }

    func clearAuthenticationSyncIssue() {
        guard let syncError = viewModel?.syncError else { return }
        guard syncError.action == .login || syncError.action == .updatePAT else { return }
        viewModel?.syncError = nil
        resolveSyncIssueWindowIfVisible()
    }

    func clearLoginRequiredSyncIssue() {
        clearAuthenticationSyncIssue()
    }

    func selectPassCLISettingsTab() {
        UserDefaults.standard.set(SettingsTab.passCLI.rawValue, forKey: DefaultsKey.selectedSettingsTab)
    }

    func openPassCLISettings() {
        selectPassCLISettingsTab()
        NSApp.activate()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
