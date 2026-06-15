import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("QuickAccessViewModel — Field Copy")
struct QuickAccessViewModelFieldCopyTests {
    @MainActor
    private func makeVM(
        fetcher: CLIItemFetcher? = nil,
        vault: PassVault = PassVault(id: "s1", name: "Personal")
    ) throws -> (QuickAccessViewModel, ClipboardManager) {
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try db.upsertVaults([vault])
        let clipboard = ClipboardManager(autoClearSeconds: 0)
        let vm = QuickAccessViewModel(
            searchService: SearchService(databaseManager: db),
            cliService: PassCLIService(),
            clipboardManager: clipboard,
            onDismiss: {},
            fetchItem: fetcher
        )
        return (vm, clipboard)
    }

    private func item(vaultId: String = "s1") -> PassItem {
        PassItem(
            id: "i1", vaultId: vaultId,
            title: "Example", itemType: .note, subtitle: "",
            url: nil, hasTOTP: false, state: "Active",
            createTime: Date(), modifyTime: Date(),
            useCount: 0, lastUsedAt: nil,
            fieldKeys: [.extra(path: .topLevel(fieldIndex: 0), name: "Memo", isSensitive: false)]
        )
    }

    @Test("ENTER on a field row calls fetcher and copies extracted value")
    @MainActor func enterCopiesField() async throws {
        let fakeMemoValue = "<<FAKE_MEMO_VALUE>>"
        let json = """
        {"id":"i1","share_id":"s1","vault_id":"v1","state":"Active","flags":[],
         "create_time":"2026-01-01T00:00:00Z","modify_time":"2026-01-01T00:00:00Z",
         "content":{"title":"","note":"","item_uuid":"u",
           "content":{"Note":null},
           "extra_fields":[{"name":"Memo","content":{"Text":"\(fakeMemoValue)"}}]}}
        """
        let cliItem = try JSONDecoder().decode(CLIItem.self, from: Data(json.utf8))
        let fetcher: CLIItemFetcher = { _, _ in cliItem }
        let (vm, clipboard) = try makeVM(fetcher: fetcher)

        vm.detailItem = item()
        let rows = vm.rows(for: try #require(vm.detailItem))
        let fieldIndex = try #require(rows.firstIndex {
            if case .field = $0 { true } else { false }
        })
        vm.selectedRowIndex = fieldIndex
        vm.handleEnter()
        await vm.inFlightCopy?.value

        #expect(clipboard.lastCopiedValue == fakeMemoValue)
    }

    @Test("copying a field uses current share id for the stable vault id")
    @MainActor func copyFieldUsesCurrentShareIdForStableVaultId() async throws {
        actor ShareIDRecorder {
            private var values: [String] = []
            func record(_ value: String) { values.append(value) }
            func recordedValues() -> [String] { values }
        }

        let fakeMemoValue = "<<FAKE_MEMO_VALUE>>"
        let json = """
        {"id":"i1","share_id":"current-share-id","vault_id":"stable-vault-id","state":"Active","flags":[],
         "create_time":"2026-01-01T00:00:00Z","modify_time":"2026-01-01T00:00:00Z",
         "content":{"title":"","note":"","item_uuid":"u",
           "content":{"Note":null},
           "extra_fields":[{"name":"Memo","content":{"Text":"\(fakeMemoValue)"}}]}}
        """
        let cliItem = try JSONDecoder().decode(CLIItem.self, from: Data(json.utf8))
        let recorder = ShareIDRecorder()
        let fetcher: CLIItemFetcher = { _, shareId in
            await recorder.record(shareId)
            return cliItem
        }
        let cliVault = CLIVault(name: "Personal", vaultId: "stable-vault-id", shareId: "current-share-id")
        let (vm, clipboard) = try makeVM(fetcher: fetcher, vault: PassVault(from: cliVault))
        let passItem = item(vaultId: "stable-vault-id")

        vm.copyField(.extra(path: .topLevel(fieldIndex: 0), name: "Memo", isSensitive: false), from: passItem)
        await vm.inFlightCopy?.value

        #expect(await recorder.recordedValues() == ["current-share-id"])
        #expect(clipboard.lastCopiedValue == fakeMemoValue)
    }
}
