import Foundation

extension SyncCoordinator {
    nonisolated static func syncErrorPresentation(
        for error: Error,
        cliSelection: PassCLISelection,
        skippedItems: [SkippedSyncItem] = [],
        diagnosticFileURL: URL? = nil
    ) -> SyncErrorPresentation {
        if let cliError = error as? CLIError, cliError.isAuthError {
            return .loginRequired()
        }

        return .genericFailure(
            diagnosticReport: SyncErrorDiagnosticReport.make(
                error: error,
                cliSelection: cliSelection,
                skippedItems: skippedItems,
                diagnosticFileURL: diagnosticFileURL
            )
        )
    }
}
