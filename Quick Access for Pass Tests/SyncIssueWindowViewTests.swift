import CoreGraphics
import Testing
@testable import Quick_Access_for_Pass

@Suite("SyncIssueWindowView state")
struct SyncIssueWindowViewTests {
    @Test("resolved state title does not imply sync success")
    func resolvedStateTitleDoesNotImplySyncSuccess() {
        #expect(SyncIssueWindowState.resolvedTitle == "No current sync diagnostics")
    }

    @Test("empty state title is explicit")
    func emptyStateTitleIsExplicit() {
        #expect(SyncIssueWindowState.emptyTitle == "No current sync errors")
    }

    @Test("resolved state announcement is explicit")
    func resolvedStateAnnouncementIsExplicit() {
        let presentation = QuickAccessSyncIssuePresentation.syncError(
            .genericFailure(diagnosticReport: "diagnostic")
        )

        #expect(SyncIssueWindowState.resolved(presentation).accessibilityAnnouncement == "No current sync diagnostics")
    }

    @Test("resolved state uses neutral status icon")
    func resolvedStateUsesNeutralStatusIcon() {
        #expect(SyncIssueWindowState.resolvedSymbolName == "info.circle.fill")
    }

    @Test("resolved state uses outer padding")
    func resolvedStateUsesOuterPadding() {
        #expect(SyncIssueWindowView.contentPadding == CGFloat(20))
    }

    @Test("resolved state labels previous diagnostics explicitly")
    func resolvedStateLabelsPreviousDiagnosticsExplicitly() {
        #expect(SyncIssueWindowView.resolvedSubtitle == "The diagnostics below are from the previous issue shown in this window.")
        #expect(SyncIssueWindowView.previousDiagnosticDisclosureTitle == "Previous diagnostic")
    }

    @Test("archived sync issue mode hides current-only recovery actions")
    func archivedSyncIssueModeHidesCurrentOnlyRecoveryActions() {
        let loginPresentation = QuickAccessSyncIssuePresentation.syncError(.loginRequired())
        let genericPresentation = QuickAccessSyncIssuePresentation.syncError(.genericFailure(diagnosticReport: "diagnostic"))

        #expect(QuickAccessSyncIssueViewMode.archived.showsLoginAction(for: loginPresentation) == false)
        #expect(QuickAccessSyncIssueViewMode.archived.showsReportActions(for: genericPresentation) == true)
        #expect(QuickAccessSyncIssueViewMode.archived.showsDismissAction(for: genericPresentation) == false)
        #expect(QuickAccessSyncIssueViewMode.current.showsDismissAction(for: genericPresentation) == true)
    }

    @Test("archived sync issue mode removes outer padding")
    func archivedSyncIssueModeRemovesOuterPadding() {
        #expect(QuickAccessSyncIssueViewMode.current.contentPadding == 20)
        #expect(QuickAccessSyncIssueViewMode.archived.contentPadding == 0)
        #expect(QuickAccessSyncIssueViewMode.current.minimumHeight == 260)
        #expect(QuickAccessSyncIssueViewMode.archived.minimumHeight == nil)
    }
}
