import Foundation

extension QuickAccessViewModel {
    func handleSyncErrorAction(_ action: SyncErrorAction) {
        switch action {
        case .login:
            requestPassCLILogin()
        case .copyAndReport:
            copyAndReportSyncError()
        }
    }

    func copyAndReportSyncError(mailtoURL: URL? = SyncErrorDiagnosticReport.mailtoURL()) {
        guard let diagnosticReport = syncError?.diagnosticReport else { return }
        writeStringToPasteboard(diagnosticReport)
        guard let mailtoURL else { return }
        _ = openURL(mailtoURL)
    }

    func requestPassCLILogin() {
        NotificationCenter.default.post(name: .passCLILoginRequested, object: nil)
    }

    func showSkippedSyncItems() {
        guard skippedSyncItems != nil else { return }
        isShowingSkippedSyncItems = true
    }

    func hideSkippedSyncItems() {
        isShowingSkippedSyncItems = false
    }

    func copySkippedSyncItemsReport() {
        guard let diagnosticReport = skippedSyncItems?.diagnosticReport else { return }
        writeStringToPasteboard(diagnosticReport)
    }

    func copyAndReportSkippedSyncItems(mailtoURL: URL? = SyncErrorDiagnosticReport.mailtoURL()) {
        copySkippedSyncItemsReport()
        guard skippedSyncItems?.diagnosticReport != nil, let mailtoURL else { return }
        _ = openURL(mailtoURL)
    }
}
