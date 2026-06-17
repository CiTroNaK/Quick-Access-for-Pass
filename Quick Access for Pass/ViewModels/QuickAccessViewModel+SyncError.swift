import Foundation

extension QuickAccessViewModel {
    var activeSyncIssuePresentation: QuickAccessSyncIssuePresentation? {
        if let syncError {
            return .syncError(syncError)
        }
        if isShowingSkippedSyncItems, let skippedSyncItems {
            return .skippedItems(skippedSyncItems)
        }
        return nil
    }

    func handleSyncErrorAction(_ action: SyncErrorAction) {
        switch action {
        case .login:
            requestPassCLILogin()
        case .copyAndReport:
            copyAndReportSyncIssue()
        }
    }

    func copySyncIssueReport() {
        guard let diagnosticReport = activeSyncIssuePresentation?.diagnosticReport else { return }
        writeStringToPasteboard(diagnosticReport)
    }

    func copyAndReportSyncIssue(mailtoURL: URL? = SyncErrorDiagnosticReport.mailtoURL()) {
        guard activeSyncIssuePresentation?.diagnosticReport != nil else { return }
        copySyncIssueReport()
        guard let mailtoURL else { return }
        _ = openURL(mailtoURL)
    }

    func dismissSyncIssue() {
        if syncError != nil {
            syncError = nil
        } else {
            hideSkippedSyncItems()
        }
    }

    func copyAndReportSyncError(mailtoURL: URL? = SyncErrorDiagnosticReport.mailtoURL()) {
        guard syncError?.diagnosticReport != nil else { return }
        copyAndReportSyncIssue(mailtoURL: mailtoURL)
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
