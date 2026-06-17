import Foundation

nonisolated enum SyncErrorAction: Equatable, Sendable {
    case login
    case copyAndReport

    var title: String {
        switch self {
        case .login:
            String(localized: "Log In", comment: "Button title for starting Proton Pass CLI login from a sync error.")
        case .copyAndReport:
            String(localized: "Copy & Report", comment: "Button title for copying sync diagnostics and opening a support email draft.")
        }
    }
}

nonisolated struct SyncErrorPresentation: Equatable, Sendable {
    let visibleMessage: String
    let diagnosticReport: String?
    let action: SyncErrorAction

    static func loginRequired() -> SyncErrorPresentation {
        SyncErrorPresentation(
            visibleMessage: String(
                localized: "Please log in to Proton Pass CLI.",
                comment: "Friendly sync error message shown when Pass CLI requires login."
            ),
            diagnosticReport: nil,
            action: .login
        )
    }

    static func genericFailure(diagnosticReport: String) -> SyncErrorPresentation {
        SyncErrorPresentation(
            visibleMessage: String(
                localized: "Sorry, there was a sync error.",
                comment: "Friendly sync error message shown instead of a long technical sync failure."
            ),
            diagnosticReport: diagnosticReport,
            action: .copyAndReport
        )
    }

    static var copyAndReportHelpText: String {
        String(
            localized: """
            Copies a sanitized diagnostic report, then opens an email draft to yes@petr.codes.

            If no email app opens, paste the copied report into your preferred email app and send it to yes@petr.codes.
            """,
            comment: "Help text for the sync error Copy & Report info icon."
        )
    }

    static var copyAndReportHelpAccessibilityLabel: String {
        String(
            localized: "Copy and report help",
            comment: "Accessibility label for the sync error Copy & Report help icon."
        )
    }
}
