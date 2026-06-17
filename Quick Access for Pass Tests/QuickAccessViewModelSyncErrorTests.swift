import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("QuickAccessViewModel sync errors")
@MainActor
struct QuickAccessViewModelSyncErrorTests {

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
            itemIndex: 7,
            itemId: "item-7",
            codingPath: "items.Index 7.content",
            reason: reason
        )
    }

    private func makeViewModel(
        writeStringToPasteboard: @escaping PasteboardStringWriter = { _ in },
        openURL: @escaping URLOpener = { _ in true }
    ) throws -> QuickAccessViewModel {
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        return QuickAccessViewModel(
            searchService: SearchService(databaseManager: db),
            cliService: PassCLIService(),
            clipboardManager: ClipboardManager(autoClearSeconds: 0),
            onDismiss: {},
            writeStringToPasteboard: writeStringToPasteboard,
            openURL: openURL
        )
    }
}
