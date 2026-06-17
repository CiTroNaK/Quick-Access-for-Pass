import Foundation

nonisolated struct QuickAccessSyncIssuePresentation: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case loginRequired
        case genericFailure
        case skippedItems
    }

    enum Preview: Equatable, Sendable {
        case none
        case diagnostic(String)
        case skippedItems(SyncSkippedItemsPresentation)
    }

    let kind: Kind
    let title: String
    let message: String
    let diagnosticReport: String?
    let preview: Preview
    let showsLoginAction: Bool
    let showsReportActions: Bool
    let showsDismissAction: Bool

    static func syncError(_ presentation: SyncErrorPresentation) -> QuickAccessSyncIssuePresentation {
        switch presentation.action {
        case .login:
            QuickAccessSyncIssuePresentation(
                kind: .loginRequired,
                title: String(
                    localized: "Login Required",
                    comment: "Title for a sync issue caused by a required Proton Pass CLI login."
                ),
                message: presentation.visibleMessage,
                diagnosticReport: nil,
                preview: .none,
                showsLoginAction: true,
                showsReportActions: false,
                showsDismissAction: false
            )
        case .copyAndReport:
            QuickAccessSyncIssuePresentation(
                kind: .genericFailure,
                title: String(localized: "Sync Error", comment: "Title for a generic sync failure."),
                message: String(
                    localized: "Sorry, there was a sync error. You can dismiss this and continue using cached items if they are available.",
                    comment: "Message for a dismissible generic sync failure."
                ),
                diagnosticReport: presentation.diagnosticReport,
                preview: .diagnostic(presentation.diagnosticReport ?? presentation.visibleMessage),
                showsLoginAction: false,
                showsReportActions: presentation.diagnosticReport != nil,
                showsDismissAction: true
            )
        }
    }

    static func skippedItems(_ presentation: SyncSkippedItemsPresentation) -> QuickAccessSyncIssuePresentation {
        QuickAccessSyncIssuePresentation(
            kind: .skippedItems,
            title: String(
                localized: "Skipped Sync Items",
                comment: "Title for sync warning listing items skipped during sync."
            ),
            message: String(
                localized: "Some items could not be parsed, but the rest of your vault synced successfully.",
                comment: "Message for skipped sync items warning."
            ),
            diagnosticReport: presentation.diagnosticReport,
            preview: .skippedItems(presentation),
            showsLoginAction: false,
            showsReportActions: true,
            showsDismissAction: true
        )
    }
}
