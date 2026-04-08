import Testing
import Foundation
@testable import Quick_Access_for_Pass

@Suite("Credential leak guardrails")
struct CredentialLeakTests {

    private static let sentinels = [
        "<<LEAK_CANARY_PASSWORD>>",
        "<<LEAK_CANARY_CVV>>",
        "<<LEAK_CANARY_MEMO>>",
    ]

    private func fakeItem() throws -> CLIItem {
        let json = """
        {"id":"i","share_id":"s","vault_id":"v","state":"Active","flags":[],
         "create_time":"2026-01-01T00:00:00Z","modify_time":"2026-01-01T00:00:00Z",
         "content":{"title":"","note":"","item_uuid":"u",
           "content":{"CreditCard":{"cardholder_name":"","card_type":"",
             "number":"<<LEAK_CANARY_PASSWORD>>","verification_number":"<<LEAK_CANARY_CVV>>",
             "expiration_date":"","pin":""}},
           "extra_fields":[{"name":"Memo","content":{"Text":"<<LEAK_CANARY_MEMO>>"}}]}}
        """
        return try JSONDecoder().decode(CLIItem.self, from: Data(json.utf8))
    }

    @MainActor
    private func makeVM(fetcher: @escaping CLIItemFetcher) throws -> (QuickAccessViewModel, ClipboardManager) {
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try db.upsertVaults([PassVault(id: "s1", name: "Personal")])
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

    @Test("lastCommand and errorMessage never contain a sentinel")
    @MainActor func lastCommandClean() async throws {
        let cliItem = try fakeItem()
        let (vm, clipboard) = try makeVM(fetcher: { _, _ in cliItem })
        let item = PassItem(
            id: "i", vaultId: "s1",
            title: "Visa", itemType: .creditCard, subtitle: "",
            url: nil, hasTOTP: false, state: "Active",
            createTime: Date(), modifyTime: Date(),
            useCount: 0, lastUsedAt: nil,
            fieldKeys: [.cardCVV, .extra(path: .topLevel(fieldIndex: 0), name: "Memo", isSensitive: false)]
        )
        vm.detailItem = item
        vm.copyField(.cardCVV, from: item)
        await vm.inFlightCopy?.value

        for sentinel in Self.sentinels {
            #expect(!vm.lastCommand.contains(sentinel))
            #expect(!(vm.errorMessage ?? "").contains(sentinel))
        }
        #expect(clipboard.lastCopiedValue == "<<LEAK_CANARY_CVV>>")
    }

    @Test("error message for stale cache is a fixed localized string")
    @MainActor func staleErrorClean() async throws {
        let json = """
        {"id":"i","share_id":"s","vault_id":"v","state":"Active","flags":[],
         "create_time":"2026-01-01T00:00:00Z","modify_time":"2026-01-01T00:00:00Z",
         "content":{"title":"","note":"","item_uuid":"u",
           "content":{"Note":null},"extra_fields":[]}}
        """
        let cliItem = try JSONDecoder().decode(CLIItem.self, from: Data(json.utf8))
        let (vm, clipboard) = try makeVM(fetcher: { _, _ in cliItem })
        let item = PassItem(
            id: "i", vaultId: "s1",
            title: "", itemType: .note, subtitle: "",
            url: nil, hasTOTP: false, state: "Active",
            createTime: Date(), modifyTime: Date(),
            useCount: 0, lastUsedAt: nil,
            fieldKeys: [.extra(path: .topLevel(fieldIndex: 0), name: "Memo", isSensitive: false)]
        )
        vm.detailItem = item
        vm.copyField(.extra(path: .topLevel(fieldIndex: 0), name: "Memo", isSensitive: false), from: item)
        await vm.inFlightCopy?.value

        for sentinel in Self.sentinels {
            #expect(!(vm.errorMessage ?? "").contains(sentinel))
        }
        #expect(vm.errorMessage == String(localized: "Field no longer available — refresh"))
        #expect(clipboard.lastCopiedValue == nil)
    }
}
