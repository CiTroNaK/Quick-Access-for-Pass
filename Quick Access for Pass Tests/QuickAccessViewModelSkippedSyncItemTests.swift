import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("QuickAccessViewModel skipped sync items")
@MainActor
struct QuickAccessViewModelSkippedSyncItemTests {
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
            "item view --share-id=share-7 --item-id=item-7 --output json",
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
