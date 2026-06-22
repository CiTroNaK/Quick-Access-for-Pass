import AppKit
import Testing
@testable import Quick_Access_for_Pass

@Suite("SyncIssueWindowController")
@MainActor
struct SyncIssueWindowControllerTests {
    @Test("show reuses existing window")
    func showReusesExistingWindow() {
        let controller = SyncIssueWindowController(
            actions: .init(
                copyReport: { _ in },
                copyAndReport: { _ in },
                copySkippedItemCommand: { _ in },
                dismissIssue: { _ in }
            ),
            presentationMode: .headless
        )
        let firstPresentation = QuickAccessSyncIssuePresentation.syncError(
            .genericFailure(diagnosticReport: "first diagnostic")
        )
        let secondPresentation = QuickAccessSyncIssuePresentation.syncError(
            .genericFailure(diagnosticReport: "second diagnostic")
        )

        controller.show(presentation: firstPresentation, relativeTo: nil)
        let firstWindow = controller.debugWindow
        controller.show(presentation: secondPresentation, relativeTo: nil)

        #expect(controller.debugWindow === firstWindow)
        #expect(controller.debugState == .current(secondPresentation))
    }

    @Test("resolved update keeps last diagnostics")
    func resolvedUpdateKeepsLastDiagnostics() {
        let controller = SyncIssueWindowController(
            actions: .init(
                copyReport: { _ in },
                copyAndReport: { _ in },
                copySkippedItemCommand: { _ in },
                dismissIssue: { _ in }
            ),
            presentationMode: .headless
        )
        let presentation = QuickAccessSyncIssuePresentation.syncError(
            .genericFailure(diagnosticReport: "diagnostic")
        )

        controller.show(presentation: presentation, relativeTo: nil)
        controller.syncIssueDidChange(nil)

        #expect(controller.debugWindow != nil)
        #expect(controller.debugState == .resolved(presentation))
    }

    @Test("new current issue replaces resolved state")
    func newCurrentIssueReplacesResolvedState() {
        let controller = SyncIssueWindowController(
            actions: .init(
                copyReport: { _ in },
                copyAndReport: { _ in },
                copySkippedItemCommand: { _ in },
                dismissIssue: { _ in }
            ),
            presentationMode: .headless
        )
        let oldPresentation = QuickAccessSyncIssuePresentation.syncError(
            .genericFailure(diagnosticReport: "old diagnostic")
        )
        let newPresentation = QuickAccessSyncIssuePresentation.syncError(
            .genericFailure(diagnosticReport: "new diagnostic")
        )

        controller.show(presentation: oldPresentation, relativeTo: nil)
        controller.syncIssueDidChange(nil)
        controller.syncIssueDidChange(newPresentation)

        #expect(controller.debugState == .current(newPresentation))
    }

    @Test("state updates preserve existing window position")
    func stateUpdatesPreserveExistingWindowPosition() throws {
        let controller = SyncIssueWindowController(
            actions: .init(
                copyReport: { _ in },
                copyAndReport: { _ in },
                copySkippedItemCommand: { _ in },
                dismissIssue: { _ in }
            ),
            presentationMode: .headless
        )
        let presentation = QuickAccessSyncIssuePresentation.syncError(
            .genericFailure(diagnosticReport: "diagnostic")
        )
        let nextPresentation = QuickAccessSyncIssuePresentation.syncError(
            .genericFailure(diagnosticReport: "next diagnostic")
        )

        controller.show(presentation: presentation, relativeTo: nil)
        #expect(controller.debugPositioningCount == 1)
        let window = try #require(controller.debugWindow)
        window.setFrameOrigin(NSPoint(x: 123, y: 456))

        controller.syncIssueDidChange(nextPresentation)

        #expect(controller.debugPositioningCount == 1)
        #expect(window.frame.origin == NSPoint(x: 123, y: 456))
        #expect(controller.debugState == .current(nextPresentation))
    }

    @Test("dismiss issue forwards current presentation and closes window")
    func dismissIssueForwardsCurrentPresentationAndClosesWindow() {
        var dismissedPresentation: QuickAccessSyncIssuePresentation?
        let controller = SyncIssueWindowController(
            actions: .init(
                copyReport: { _ in },
                copyAndReport: { _ in },
                copySkippedItemCommand: { _ in },
                dismissIssue: { presentation in dismissedPresentation = presentation }
            ),
            presentationMode: .headless
        )
        let presentation = QuickAccessSyncIssuePresentation.syncError(
            .genericFailure(diagnosticReport: "diagnostic")
        )

        controller.show(presentation: presentation, relativeTo: nil)
        controller.debugDismissIssue()

        #expect(dismissedPresentation == presentation)
        #expect(controller.debugWindow == nil)
    }

    @Test("copy report uses retained resolved presentation")
    func copyReportUsesRetainedResolvedPresentation() {
        var copiedPresentation: QuickAccessSyncIssuePresentation?
        let controller = SyncIssueWindowController(
            actions: .init(
                copyReport: { presentation in copiedPresentation = presentation },
                copyAndReport: { _ in },
                copySkippedItemCommand: { _ in },
                dismissIssue: { _ in }
            ),
            presentationMode: .headless
        )
        let presentation = QuickAccessSyncIssuePresentation.syncError(
            .genericFailure(diagnosticReport: "diagnostic")
        )

        controller.show(presentation: presentation, relativeTo: nil)
        controller.syncIssueDidChange(nil)
        controller.debugCopyReport()

        #expect(copiedPresentation == presentation)
    }
}
