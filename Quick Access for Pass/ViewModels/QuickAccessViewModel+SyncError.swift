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

    var currentSyncDiagnosticsPresentation: QuickAccessSyncIssuePresentation? {
        if let syncError, syncError.action == .copyAndReport {
            return .syncError(syncError)
        }
        if let skippedSyncItems {
            return .skippedItems(skippedSyncItems)
        }
        return nil
    }

    func handleSyncErrorAction(_ action: SyncErrorAction) {
        switch action {
        case .login:
            requestPassCLILogin()
        case .updatePAT:
            break
        case .copyAndReport:
            copyAndReportSyncIssue()
        }
    }

    func copySyncIssueReport() {
        guard let presentation = currentSyncDiagnosticsPresentation ?? activeSyncIssuePresentation else { return }
        copySyncIssueReport(presentation)
    }

    func copySyncIssueReport(_ presentation: QuickAccessSyncIssuePresentation) {
        guard let diagnosticReport = presentation.diagnosticReport else { return }
        writeStringToPasteboard(diagnosticReport)
    }

    func copyAndReportSyncIssue(mailtoURL: URL? = SyncErrorDiagnosticReport.mailtoURL()) {
        guard let presentation = currentSyncDiagnosticsPresentation ?? activeSyncIssuePresentation else { return }
        copyAndReportSyncIssue(presentation, mailtoURL: mailtoURL)
    }

    func copyAndReportSyncIssue(
        _ presentation: QuickAccessSyncIssuePresentation,
        mailtoURL: URL? = SyncErrorDiagnosticReport.mailtoURL()
    ) {
        copySyncIssueReport(presentation)
        guard presentation.diagnosticReport != nil, let mailtoURL else { return }
        _ = openURL(mailtoURL)
    }

    func dismissSyncIssue() {
        if syncError != nil {
            syncError = nil
        } else {
            hideSkippedSyncItems()
        }
    }

    func dismissSyncIssue(_ presentation: QuickAccessSyncIssuePresentation) {
        switch presentation.kind {
        case .genericFailure, .loginRequired, .invalidPAT:
            syncError = nil
        case .skippedItems:
            skippedSyncItems = nil
            isShowingSkippedSyncItems = false
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

    func copySkippedSyncItemInspectCommand(_ item: SkippedSyncItem) {
        writeStringToPasteboard(item.inspectCommand(cliSelection: cliService.cliSelection))
    }

    func copyAndReportSkippedSyncItems(mailtoURL: URL? = SyncErrorDiagnosticReport.mailtoURL()) {
        copySkippedSyncItemsReport()
        guard skippedSyncItems?.diagnosticReport != nil, let mailtoURL else { return }
        _ = openURL(mailtoURL)
    }
}
