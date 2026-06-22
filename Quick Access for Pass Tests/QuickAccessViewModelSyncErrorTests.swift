import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("QuickAccessViewModel sync errors")
@MainActor
struct QuickAccessViewModelSyncErrorTests {

    @Test("generic sync error maps to unified issue presentation")
    func genericSyncErrorMapsToUnifiedIssuePresentation() throws {
        let vm = try makeViewModel()
        vm.syncError = .genericFailure(diagnosticReport: "diagnostic line 1\ndiagnostic line 2")

        let presentation = try #require(vm.activeSyncIssuePresentation)

        #expect(presentation.kind == .genericFailure)
        #expect(presentation.title == "Sync Error")
        #expect(presentation.message == "Sorry, there was a sync error. You can dismiss this and continue using cached items if they are available.")
        #expect(presentation.diagnosticReport == "diagnostic line 1\ndiagnostic line 2")
        #expect(presentation.showsLoginAction == false)
        #expect(presentation.showsReportActions)
        #expect(presentation.showsDismissAction)
        if case .diagnostic(let preview) = presentation.preview {
            #expect(preview == "diagnostic line 1\ndiagnostic line 2")
        } else {
            Issue.record("Expected diagnostic preview")
        }
    }

    @Test("login required sync error maps to unified issue presentation")
    func loginRequiredSyncErrorMapsToUnifiedIssuePresentation() throws {
        let vm = try makeViewModel()
        vm.syncError = .loginRequired()

        let presentation = try #require(vm.activeSyncIssuePresentation)

        #expect(presentation.kind == .loginRequired)
        #expect(presentation.title == "Login Required")
        #expect(presentation.message == "Please log in to Proton Pass CLI.")
        #expect(presentation.diagnosticReport == nil)
        #expect(presentation.preview == .none)
        #expect(presentation.showsLoginAction)
        #expect(presentation.showsReportActions == false)
        #expect(presentation.showsDismissAction == false)
    }

    @Test("invalid PAT sync error stays out of diagnostics")
    func invalidPATSyncErrorStaysOutOfDiagnostics() throws {
        let vm = try makeViewModel()
        vm.syncError = .invalidPAT(
            userFacingMessage: "Personal access token is invalid, expired, or deleted. Replace it in Settings → Pass CLI or log in normally."
        )

        let presentation = try #require(vm.activeSyncIssuePresentation)

        #expect(presentation.kind == .invalidPAT)
        #expect(presentation.title == "Personal Access Token Invalid")
        #expect(presentation.message == "Personal access token is invalid, expired, or deleted. Replace it in Settings → Pass CLI or log in normally.")
        #expect(presentation.diagnosticReport == nil)
        #expect(presentation.preview == .none)
        #expect(presentation.showsLoginAction == false)
        #expect(presentation.showsReportActions == false)
        #expect(presentation.showsDismissAction == false)
        #expect(vm.currentSyncDiagnosticsPresentation == nil)
    }

    @Test("skipped items map to unified issue presentation")
    func skippedItemsMapToUnifiedIssuePresentation() throws {
        let vm = try makeViewModel()
        let skippedItems = try #require(SyncSkippedItemsPresentation.make(
            skippedItems: [makeSkippedItem(reason: "failed for user@example.com")],
            diagnosticFileURL: nil
        ))
        vm.skippedSyncItems = skippedItems
        vm.showSkippedSyncItems()

        let presentation = try #require(vm.activeSyncIssuePresentation)

        #expect(presentation.kind == .skippedItems)
        #expect(presentation.title == "Skipped Sync Items")
        #expect(presentation.message == "Some items could not be parsed, but the rest of your vault synced successfully.")
        #expect(presentation.diagnosticReport == skippedItems.diagnosticReport)
        #expect(presentation.showsLoginAction == false)
        #expect(presentation.showsReportActions)
        #expect(presentation.showsDismissAction)
        if case .skippedItems(let preview) = presentation.preview {
            #expect(preview == skippedItems)
        } else {
            Issue.record("Expected skipped-items preview")
        }
    }

    @Test("login required does not produce diagnostics window presentation")
    func loginRequiredDoesNotProduceDiagnosticsWindowPresentation() throws {
        let vm = try makeViewModel()
        vm.syncError = .loginRequired()

        #expect(vm.currentSyncDiagnosticsPresentation == nil)
    }

    @Test("generic sync error produces diagnostics window presentation")
    func genericSyncErrorProducesDiagnosticsWindowPresentation() throws {
        let vm = try makeViewModel()
        vm.syncError = .genericFailure(diagnosticReport: "diagnostic")

        let presentation = try #require(vm.currentSyncDiagnosticsPresentation)

        #expect(presentation.kind == .genericFailure)
        #expect(presentation.diagnosticReport == "diagnostic")
    }

    @Test("skipped items produce diagnostics window presentation without inline display flag")
    func skippedItemsProduceDiagnosticsWindowPresentationWithoutInlineDisplayFlag() throws {
        let vm = try makeViewModel()
        let skippedItems = try #require(SyncSkippedItemsPresentation.make(
            skippedItems: [makeSkippedItem()],
            diagnosticFileURL: nil
        ))
        vm.skippedSyncItems = skippedItems
        vm.isShowingSkippedSyncItems = false

        let presentation = try #require(vm.currentSyncDiagnosticsPresentation)

        #expect(presentation.kind == .skippedItems)
        #expect(presentation.diagnosticReport == skippedItems.diagnosticReport)
    }

    @Test("explicit diagnostics report copy uses retained window presentation")
    func explicitDiagnosticsReportCopyUsesRetainedWindowPresentation() throws {
        var copiedText: String?
        let vm = try makeViewModel(writeStringToPasteboard: { copiedText = $0 })
        let skippedItems = try #require(SyncSkippedItemsPresentation.make(
            skippedItems: [makeSkippedItem()],
            diagnosticFileURL: nil
        ))
        let presentation = QuickAccessSyncIssuePresentation.skippedItems(skippedItems)
        vm.skippedSyncItems = nil
        vm.isShowingSkippedSyncItems = false

        vm.copySyncIssueReport(presentation)

        #expect(copiedText == skippedItems.diagnosticReport)
    }

    @Test("generic sync error takes presentation priority over skipped items")
    func genericSyncErrorTakesPresentationPriorityOverSkippedItems() throws {
        let vm = try makeViewModel()
        vm.syncError = .genericFailure(diagnosticReport: "generic diagnostic")
        vm.skippedSyncItems = .make(skippedItems: [makeSkippedItem()], diagnosticFileURL: nil)
        vm.showSkippedSyncItems()

        let presentation = try #require(vm.activeSyncIssuePresentation)

        #expect(presentation.kind == .genericFailure)
        #expect(presentation.diagnosticReport == "generic diagnostic")
    }

    @Test("dismissed generic sync issue reveals item content state")
    func dismissedGenericSyncIssueRevealsItemContentState() throws {
        let vm = try makeViewModel()
        vm.syncError = .genericFailure(diagnosticReport: "generic diagnostic")
        vm.dismissSyncIssue()

        let state = QuickAccessViewContentState.resolve(QuickAccessViewContentInputs(
            isLocked: false,
            hasDetailItem: false,
            hasItems: true,
            hasSyncError: vm.syncError != nil,
            hasSkippedItemDetails: vm.isShowingSkippedSyncItems && vm.skippedSyncItems != nil,
            hasErrorMessage: false,
            searchQuery: "github"
        ))

        #expect(state == .itemContent)
    }

    @Test("unified sync issue view accepts a unified presentation")
    func unifiedSyncIssueViewAcceptsUnifiedPresentation() throws {
        let vm = try makeViewModel()
        vm.syncError = .genericFailure(diagnosticReport: "diagnostic")
        let presentation = try #require(vm.activeSyncIssuePresentation)

        let view = QuickAccessSyncIssueView(
            presentation: presentation,
            performLogin: {},
            copyReport: {},
            copyAndReport: {},
            copySkippedItemCommand: { _ in },
            dismiss: {}
        )

        #expect(view.presentation == presentation)
    }

    @Test("copy and report copies diagnostics before opening email")
    func copyAndReportCopiesBeforeOpeningEmail() throws {
        var events: [String] = []
        var copiedText: String?
        var openedURL: URL?
        let vm = try makeViewModel(
            writeStringToPasteboard: { text in
                events.append("copy")
                copiedText = text
            },
            openURL: { url in
                events.append("open")
                openedURL = url
                return true
            }
        )
        vm.syncError = .genericFailure(diagnosticReport: "sanitized diagnostic report")

        vm.handleSyncErrorAction(.copyAndReport)

        #expect(events == ["copy", "open"])
        #expect(copiedText == "sanitized diagnostic report")
        #expect(openedURL?.absoluteString.hasPrefix("mailto:yes@petr.codes") == true)
    }

    @Test("copy and report still copies diagnostics if mail URL cannot be built")
    func copyAndReportStillCopiesIfMailURLCannotBeBuilt() throws {
        var copiedText: String?
        var didOpen = false
        let vm = try makeViewModel(
            writeStringToPasteboard: { copiedText = $0 },
            openURL: { _ in
                didOpen = true
                return true
            }
        )
        vm.syncError = .genericFailure(diagnosticReport: "diagnostic")

        vm.copyAndReportSyncError(mailtoURL: nil)

        #expect(copiedText == "diagnostic")
        #expect(didOpen == false)
    }

    @Test("copy sync issue report copies generic diagnostic report")
    func copySyncIssueReportCopiesGenericDiagnosticReport() throws {
        var copiedText: String?
        let vm = try makeViewModel(writeStringToPasteboard: { copiedText = $0 })
        vm.syncError = .genericFailure(diagnosticReport: "generic diagnostic")

        vm.copySyncIssueReport()

        #expect(copiedText == "generic diagnostic")
    }

    @Test("copy sync issue report copies skipped items report")
    func copySyncIssueReportCopiesSkippedItemsReport() throws {
        var copiedText: String?
        let vm = try makeViewModel(writeStringToPasteboard: { copiedText = $0 })
        let skippedItems = try #require(SyncSkippedItemsPresentation.make(skippedItems: [makeSkippedItem()], diagnosticFileURL: nil))
        vm.skippedSyncItems = skippedItems
        vm.showSkippedSyncItems()

        vm.copySyncIssueReport()

        #expect(copiedText == skippedItems.diagnosticReport)
    }

    @Test("copy and report sync issue copies before opening email")
    func copyAndReportSyncIssueCopiesBeforeOpeningEmail() throws {
        var events: [String] = []
        let vm = try makeViewModel(
            writeStringToPasteboard: { _ in events.append("copy") },
            openURL: { _ in
                events.append("open")
                return true
            }
        )
        vm.syncError = .genericFailure(diagnosticReport: "generic diagnostic")

        vm.copyAndReportSyncIssue()

        #expect(events == ["copy", "open"])
    }

    @Test("dismiss sync issue clears generic sync error without clearing search")
    func dismissSyncIssueClearsGenericSyncErrorWithoutClearingSearch() throws {
        let vm = try makeViewModel()
        vm.searchQuery = "github"
        vm.syncError = .genericFailure(diagnosticReport: "generic diagnostic")

        vm.dismissSyncIssue()

        #expect(vm.syncError == nil)
        #expect(vm.searchQuery == "github")
    }

    @Test("dismiss diagnostics presentation clears generic sync error")
    func dismissDiagnosticsPresentationClearsGenericSyncError() throws {
        let vm = try makeViewModel()
        vm.syncError = .genericFailure(diagnosticReport: "generic diagnostic")
        let presentation = try #require(vm.currentSyncDiagnosticsPresentation)

        vm.dismissSyncIssue(presentation)

        #expect(vm.syncError == nil)
    }

    @Test("dismiss diagnostics presentation clears skipped diagnostics")
    func dismissDiagnosticsPresentationClearsSkippedDiagnostics() throws {
        let vm = try makeViewModel()
        let skippedItems = try #require(SyncSkippedItemsPresentation.make(skippedItems: [makeSkippedItem()], diagnosticFileURL: nil))
        vm.skippedSyncItems = skippedItems
        vm.showSkippedSyncItems()
        let presentation = QuickAccessSyncIssuePresentation.skippedItems(skippedItems)

        vm.dismissSyncIssue(presentation)

        #expect(vm.skippedSyncItems == nil)
        #expect(vm.isShowingSkippedSyncItems == false)
    }

    @Test("dismiss sync issue hides skipped item details without deleting skipped summary")
    func dismissSyncIssueHidesSkippedItemDetailsWithoutDeletingSkippedSummary() throws {
        let vm = try makeViewModel()
        let skippedItems = try #require(SyncSkippedItemsPresentation.make(skippedItems: [makeSkippedItem()], diagnosticFileURL: nil))
        vm.skippedSyncItems = skippedItems
        vm.showSkippedSyncItems()

        vm.dismissSyncIssue()

        #expect(vm.isShowingSkippedSyncItems == false)
        #expect(vm.skippedSyncItems == skippedItems)
    }

    @Test("login action posts Pass CLI login notification", .timeLimit(.minutes(1)))
    func loginActionPostsPassCLILoginNotification() async throws {
        let vm = try makeViewModel()
        vm.syncError = .loginRequired()

        await confirmation { confirmed in
            let task = Task {
                for await _ in NotificationCenter.default.notifications(named: .passCLILoginRequested) {
                    confirmed()
                    break
                }
            }
            await Task.yield()

            vm.handleSyncErrorAction(.login)
            await task.value
        }
    }

    @Test("clear for lock clears sync error state")
    func clearForLockClearsSyncErrorState() throws {
        let vm = try makeViewModel()
        vm.syncError = .genericFailure(diagnosticReport: "diagnostic")

        vm.clearForLock()

        #expect(vm.syncError == nil)
    }

    @Test("skipped item report copies sanitized summaries")
    func skippedItemReportCopiesSanitizedSummaries() throws {
        var copiedText: String?
        let vm = try makeViewModel(writeStringToPasteboard: { copiedText = $0 })
        vm.skippedSyncItems = .make(
            skippedItems: [makeSkippedItem(reason: "failed for user@example.com at /Users/alice/item")],
            diagnosticFileURL: URL(fileURLWithPath: "/Users/alice/Library/Caches/SyncDiagnostics/report.txt")
        )

        vm.copySkippedSyncItemsReport()

        #expect(copiedText?.contains("Skipped Sync Items Report") == true)
        #expect(copiedText?.contains("item_id=item-7") == true)
        #expect(copiedText?.contains("user@example.com") == false)
        #expect(copiedText?.contains("/Users/alice") == false)
        #expect(copiedText?.contains("~/Library/Caches/SyncDiagnostics/report.txt") == true)
    }

    @Test("copy and report skipped items copies before opening email")
    func copyAndReportSkippedItemsCopiesBeforeOpeningEmail() throws {
        var events: [String] = []
        let vm = try makeViewModel(
            writeStringToPasteboard: { _ in events.append("copy") },
            openURL: { _ in
                events.append("open")
                return true
            }
        )
        vm.skippedSyncItems = .make(skippedItems: [makeSkippedItem()], diagnosticFileURL: nil)

        vm.copyAndReportSkippedSyncItems()

        #expect(events == ["copy", "open"])
    }

    @Test("copy skipped item inspect command copies ready-to-run CLI command")
    func copySkippedItemInspectCommandCopiesReadyToRunCLICommand() throws {
        var copiedText: String?
        let vm = try makeViewModel(
            cliService: PassCLIService(cliPath: "/Applications/Quick Access for Pass.app/Contents/Helpers/pass-cli-arm64"),
            writeStringToPasteboard: { copiedText = $0 }
        )

        vm.copySkippedSyncItemInspectCommand(makeSkippedItem())

        #expect(copiedText == [
            "'/Applications/Quick Access for Pass.app/Contents/Helpers/pass-cli-arm64'",
            "item view --share-id share-7 --item-id item-7 --output json",
        ].joined(separator: " "))
    }

    @Test("search hides skipped item details")
    func searchHidesSkippedItemDetails() throws {
        let vm = try makeViewModel()
        vm.skippedSyncItems = .make(skippedItems: [makeSkippedItem()], diagnosticFileURL: nil)
        vm.showSkippedSyncItems()

        vm.performSearch(query: "github")

        #expect(vm.isShowingSkippedSyncItems == false)
    }

    private func makeSkippedItem(reason: String = "expected String") -> SkippedSyncItem {
        SkippedSyncItem(
            vaultId: "vault",
            vaultName: "Personal",
            shareId: "share-7",
            itemIndex: 7,
            itemId: "item-7",
            codingPath: "items.Index 7.content",
            reason: reason
        )
    }

    private func makeViewModel(
        cliService: PassCLIService = PassCLIService(),
        writeStringToPasteboard: @escaping PasteboardStringWriter = { _ in },
        openURL: @escaping URLOpener = { _ in true }
    ) throws -> QuickAccessViewModel {
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        return QuickAccessViewModel(
            searchService: SearchService(databaseManager: db),
            cliService: cliService,
            clipboardManager: ClipboardManager(autoClearSeconds: 0),
            onDismiss: {},
            writeStringToPasteboard: writeStringToPasteboard,
            openURL: openURL
        )
    }
}
