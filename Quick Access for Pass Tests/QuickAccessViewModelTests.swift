import Testing
import Foundation
import AppKit
import GRDB
@testable import Quick_Access_for_Pass

// MARK: - Helpers

@MainActor
private final class DismissTracker {
    var called = false
}

@MainActor
private func makeViewModel(dismissTracker: DismissTracker = DismissTracker()) throws -> (QuickAccessViewModel, DismissTracker) {
    let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
    let search = SearchService(databaseManager: db)
    let cli = PassCLIService()
    let clipboard = ClipboardManager(autoClearSeconds: 0)
    dismissTracker.called = false
    let vm = QuickAccessViewModel(
        searchService: search,
        cliService: cli,
        clipboardManager: clipboard,
        onDismiss: { dismissTracker.called = true }
    )
    return (vm, dismissTracker)
}

@MainActor
private func makeViewModelWithItems() throws -> (QuickAccessViewModel, DatabaseManager) {
    let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
    try db.upsertVaults([PassVault(id: "s1", name: "Personal")])
    let items = [
        PassItem(id: "1", vaultId: "s1",
                 title: "GitHub", itemType: .login, subtitle: "user@github.com",
                 url: "https://github.com", hasTOTP: true, state: "Active",
                 createTime: Date(), modifyTime: Date(),
                 useCount: 5, lastUsedAt: Date()),
        PassItem(id: "2", vaultId: "s1",
                 title: "GitLab", itemType: .login, subtitle: "user@gitlab.com",
                 url: nil, hasTOTP: false, state: "Active",
                 createTime: Date(), modifyTime: Date(),
                 useCount: 1, lastUsedAt: nil),
        PassItem(id: "3", vaultId: "s1",
                 title: "Visa Card", itemType: .creditCard, subtitle: "John Doe",
                 url: nil, hasTOTP: false, state: "Active",
                 createTime: Date(), modifyTime: Date(),
                 useCount: 0, lastUsedAt: nil),
    ]
    try db.upsertItems(items)
    let vm = QuickAccessViewModel(
        searchService: SearchService(databaseManager: db),
        cliService: PassCLIService(),
        clipboardManager: ClipboardManager(autoClearSeconds: 0),
        onDismiss: {}
    )
    vm.performSearch(query: "git")
    return (vm, db)
}

// MARK: - Tests

@Suite("QuickAccessViewModel — Search")
struct QuickAccessViewModelSearchTests {

    @Test("empty query clears results")
    @MainActor func emptyQueryClearsResults() throws {
        let (vm, _) = try makeViewModelWithItems()
        #expect(vm.items.count == 2)
        vm.performSearch(query: "  ")
        #expect(vm.items.isEmpty)
        #expect(vm.selectedIndex == 0)
        #expect(vm.errorMessage == nil)
    }

    @Test("search resets selectedIndex to 0")
    @MainActor func searchResetsSelection() throws {
        let (vm, _) = try makeViewModelWithItems()
        vm.selectedIndex = 1
        vm.performSearch(query: "github")
        #expect(vm.selectedIndex == 0)
    }

    @Test("search closes detail panel")
    @MainActor func searchClosesDetail() throws {
        let (vm, _) = try makeViewModelWithItems()
        vm.showDetail()
        #expect(vm.detailItem != nil)
        vm.performSearch(query: "lab")
        #expect(vm.detailItem == nil)
    }
}

@Suite("QuickAccessViewModel — Navigation")
struct QuickAccessViewModelNavigationTests {

    @Test("moveSelection clamps to valid range")
    @MainActor func moveSelectionClampsRange() throws {
        let (vm, _) = try makeViewModelWithItems()
        vm.selectedIndex = 0
        vm.moveSelection(by: -5)
        #expect(vm.selectedIndex == 0)

        vm.moveSelection(by: 100)
        #expect(vm.selectedIndex == vm.items.count - 1)
    }

    @Test("moveSelection does nothing when no items")
    @MainActor func moveSelectionNoItems() throws {
        let (vm, _) = try makeViewModel()
        vm.moveSelection(by: 1)
        #expect(vm.selectedIndex == 0)
    }

    @Test("showDetail opens detail for selected item")
    @MainActor func showDetailOpensItem() throws {
        let (vm, _) = try makeViewModelWithItems()
        vm.selectedIndex = 0
        vm.showDetail()
        #expect(vm.detailItem?.title == "GitHub")
        #expect(vm.selectedRowIndex == 0)
    }

    @Test("showDetail does nothing when no items")
    @MainActor func showDetailNoItems() throws {
        let (vm, _) = try makeViewModel()
        vm.showDetail()
        #expect(vm.detailItem == nil)
    }

    @Test("hideDetail clears detail and resets row index")
    @MainActor func hideDetailClearsState() throws {
        let (vm, _) = try makeViewModelWithItems()
        vm.showDetail()
        vm.selectedRowIndex = 2
        vm.hideDetail()
        #expect(vm.detailItem == nil)
        #expect(vm.selectedRowIndex == 0)
    }

    @Test("moveRowSelection clamps to row count")
    @MainActor func moveRowSelectionClamped() throws {
        let (vm, _) = try makeViewModelWithItems()
        vm.showDetail()
        vm.moveRowSelection(by: 100)
        let rows = vm.rows(for: try #require(vm.detailItem))
        #expect(vm.selectedRowIndex == rows.count - 1)

        vm.moveRowSelection(by: -100)
        #expect(vm.selectedRowIndex == 0)
    }

    @Test("moveRowSelection does nothing when no detail item")
    @MainActor func moveRowSelectionNoDetail() throws {
        let (vm, _) = try makeViewModel()
        vm.moveRowSelection(by: 1)
        #expect(vm.selectedRowIndex == 0)
    }
}

@Suite("QuickAccessViewModel — Actions mapping")
struct QuickAccessViewModelActionTests {

    @Test("defaultAction for login is copyPassword")
    @MainActor func defaultActionLogin() throws {
        let (vm, _) = try makeViewModel()
        #expect(vm.defaultAction(for: .login) == .copyPassword)
    }

    @Test("defaultAction for non-login types is copyPrimary")
    @MainActor func defaultActionNonLogin() throws {
        let (vm, _) = try makeViewModel()
        for type in [ItemType.creditCard, .note, .identity, .alias, .sshKey, .wifi, .custom] {
            #expect(vm.defaultAction(for: type) == .copyPrimary)
        }
    }

    @Test("actionsForItem includes openURL when URL present")
    @MainActor func actionsIncludeOpenURL() throws {
        let (vm, _) = try makeViewModelWithItems()
        let github = try #require(vm.items.first { $0.title == "GitHub" })
        let actions = vm.actionsForItem(github)
        #expect(actions.contains { $0.action == .openURL })
    }

    @Test("actionsForItem excludes openURL when URL absent")
    @MainActor func actionsExcludeOpenURLWhenNone() throws {
        let (vm, _) = try makeViewModelWithItems()
        let gitlab = try #require(vm.items.first { $0.title == "GitLab" })
        let actions = vm.actionsForItem(gitlab)
        #expect(actions.contains { $0.action == .openURL } == false)
    }

    @Test("actionsForItem returns single primary action for creditCard")
    @MainActor func actionsForCreditCard() throws {
        let (vm, _) = try makeViewModelWithItems()
        vm.performSearch(query: "visa")
        let card = try #require(vm.items.first)
        let actions = vm.actionsForItem(card)
        #expect(actions.first?.action == .copyPrimary)
        #expect(actions.first?.label == "Copy Card Number")
    }

    @Test("copyUsername action calls dismiss")
    @MainActor func copyUsernameCallsDismiss() throws {
        let (vm, _) = try makeViewModelWithItems()
        let github = try #require(vm.items.first { $0.title == "GitHub" })
        let tracker = DismissTracker()
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let dismissingVM = QuickAccessViewModel(
            searchService: SearchService(databaseManager: db),
            cliService: PassCLIService(),
            clipboardManager: ClipboardManager(autoClearSeconds: 0),
            onDismiss: { tracker.called = true }
        )
        dismissingVM.handleAction(.copyUsername, for: github)
        #expect(tracker.called)
    }

    @Test("openURL with no URL does not dismiss")
    @MainActor func openURLWithoutURLDoesNotDismiss() throws {
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let tracker = DismissTracker()
        let vm = QuickAccessViewModel(
            searchService: SearchService(databaseManager: db),
            cliService: PassCLIService(),
            clipboardManager: ClipboardManager(autoClearSeconds: 0),
            onDismiss: { tracker.called = true }
        )
        let item = PassItem(
            id: "n1", vaultId: "s1",
            title: "Note", itemType: .note, subtitle: "",
            url: nil, hasTOTP: false, state: "Active",
            createTime: Date(), modifyTime: Date(),
            useCount: 0, lastUsedAt: nil
        )

        vm.handleAction(.openURL, for: item)

        #expect(tracker.called == false)
        #expect(vm.isActionLoading == false)
        #expect(vm.errorMessage == nil)
    }
}

@Suite("QuickAccessViewModel — Detail Rows")
struct QuickAccessViewModelDetailRowTests {

    @MainActor
    private func makeVM(
        fetcher: CLIItemFetcher? = nil,
        items: [PassItem] = [],
        presentLargeType: LargeTypePresenter? = nil
    ) throws -> (QuickAccessViewModel, ClipboardManager) {
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try db.upsertVaults([PassVault(id: "s1", name: "Personal")])
        if !items.isEmpty { try db.upsertItems(items) }
        let clipboard = ClipboardManager(autoClearSeconds: 0)
        let vm = QuickAccessViewModel(
            searchService: SearchService(databaseManager: db),
            cliService: PassCLIService(),
            clipboardManager: clipboard,
            onDismiss: {},
            fetchItem: fetcher,
            presentLargeType: presentLargeType
        )
        return (vm, clipboard)
    }

    private func item(fieldKeys: [FieldKey]) -> PassItem {
        PassItem(
            id: "i1", vaultId: "s1",
            title: "Example", itemType: .login, subtitle: "user",
            url: "https://example.com", hasTOTP: true, state: "Active",
            createTime: Date(), modifyTime: Date(),
            useCount: 0, lastUsedAt: nil,
            fieldKeys: fieldKeys
        )
    }

    private func creditCardItem(fieldKeys: [FieldKey]) -> PassItem {
        PassItem(
            id: "c1", vaultId: "s1",
            title: "Visa", itemType: .creditCard, subtitle: "John",
            url: nil, hasTOTP: false, state: "Active",
            createTime: Date(), modifyTime: Date(),
            useCount: 0, lastUsedAt: nil,
            fieldKeys: fieldKeys
        )
    }

    @Test("top-group rows match legacy actionsForItem output")
    @MainActor func topGroupParity() throws {
        let (vm, _) = try makeVM()
        let passItem = item(fieldKeys: [.email])
        let rows = vm.rows(for: passItem)
        let topGroup = rows.prefix(while: {
            if case .namedAction = $0 { true } else { false }
        })
        let legacy = vm.actionsForItem(passItem)
        #expect(topGroup.count == legacy.count)
        for (row, tuple) in zip(topGroup, legacy) {
            if case .namedAction(let action, let label, let shortcut) = row {
                #expect(action == tuple.action)
                #expect(label == tuple.label)
                #expect(shortcut == tuple.shortcut)
            } else {
                Issue.record("expected namedAction")
            }
        }
    }

    @Test("bottom group appends after top group in order")
    @MainActor func bottomGroupOrder() throws {
        let (vm, _) = try makeVM()
        let memo = FieldKey.extra(path: .topLevel(fieldIndex: 0), name: "Memo", isSensitive: false)
        let passItem = creditCardItem(fieldKeys: [.cardholderName, .cardCVV, memo])
        let rows = vm.rows(for: passItem)
        let fieldRows = rows.compactMap { row -> FieldKey? in
            if case .field(let key, _, _) = row { key } else { nil }
        }
        #expect(fieldRows == [.cardholderName, .cardCVV, memo])
    }

    @Test("moveRowSelection skips section headers")
    @MainActor func skipHeaders() throws {
        let (vm, _) = try makeVM()
        vm.detailItem = creditCardItem(fieldKeys: [
            .sectionHeader(name: "Group A"),
            .cardholderName,
            .sectionHeader(name: "Group B"),
            .cardCVV,
        ])
        vm.selectedRowIndex = 0
        vm.moveRowSelection(by: 1)
        let rows = vm.rows(for: try #require(vm.detailItem))
        guard case .field(let key, _, _) = rows[vm.selectedRowIndex] else {
            Issue.record("expected .field")
            return
        }
        #expect(key == .cardholderName)
    }

    @Test("ENTER on a field row calls fetcher and copies extracted value")
    @MainActor func enterCopiesField() async throws {
        let fakePassword = "<<FAKE_MEMO_VALUE>>"
        let json = """
        {"id":"i1","share_id":"s1","vault_id":"v1","state":"Active","flags":[],
         "create_time":"2026-01-01T00:00:00Z","modify_time":"2026-01-01T00:00:00Z",
         "content":{"title":"","note":"","item_uuid":"u",
           "content":{"Note":null},
           "extra_fields":[{"name":"Memo","content":{"Text":"\(fakePassword)"}}]}}
        """
        let cliItem = try JSONDecoder().decode(CLIItem.self, from: Data(json.utf8))
        let fetcher: CLIItemFetcher = { _, _ in cliItem }
        let (vm, clipboard) = try makeVM(fetcher: fetcher)

        vm.detailItem = item(fieldKeys: [.extra(path: .topLevel(fieldIndex: 0), name: "Memo", isSensitive: false)])
        let rows = vm.rows(for: try #require(vm.detailItem))
        let fieldIndex = try #require(rows.firstIndex {
            if case .field = $0 { true } else { false }
        })
        vm.selectedRowIndex = fieldIndex
        vm.handleEnter()
        await vm.inFlightCopy?.value
        #expect(clipboard.lastCopiedValue == fakePassword)
    }

    @Test("stale cache: empty extracted value sets localized error and does not copy")
    @MainActor func staleCacheError() async throws {
        let json = """
        {"id":"i1","share_id":"s1","vault_id":"v1","state":"Active","flags":[],
         "create_time":"2026-01-01T00:00:00Z","modify_time":"2026-01-01T00:00:00Z",
         "content":{"title":"","note":"","item_uuid":"u",
           "content":{"Note":null},"extra_fields":[]}}
        """
        let cliItem = try JSONDecoder().decode(CLIItem.self, from: Data(json.utf8))
        let fetcher: CLIItemFetcher = { _, _ in cliItem }
        let (vm, clipboard) = try makeVM(fetcher: fetcher)
        vm.detailItem = item(fieldKeys: [.extra(path: .topLevel(fieldIndex: 0), name: "Memo", isSensitive: false)])
        let rows = vm.rows(for: try #require(vm.detailItem))
        vm.selectedRowIndex = try #require(rows.firstIndex {
            if case .field = $0 { true } else { false }
        })
        vm.handleEnter()
        await vm.inFlightCopy?.value
        #expect(vm.errorMessage == String(localized: "Field no longer available — refresh"))
        #expect(clipboard.lastCopiedValue == nil)
    }

    @Test("copyLabel uses shared localized format for built-in fields")
    @MainActor func builtInCopyLabelUsesFormat() throws {
        let (vm, _) = try makeVM()
        #expect(
            vm.debugCopyLabel(for: .cardCVV)
                == String(format: String(localized: "%@ copied"), locale: .current, "CVV")
        )
    }

    @Test("copyLabel uses shared localized format for custom fields")
    @MainActor func customCopyLabelUsesFormat() throws {
        let (vm, _) = try makeVM()
        #expect(
            vm.debugCopyLabel(
                for: .extra(path: .topLevel(fieldIndex: 0), name: "Recovery Code", isSensitive: true)
            ) == String(format: String(localized: "%@ copied"), locale: .current, "Recovery Code")
        )
    }

    @Test("stale cache error remains set while detail item stays open")
    @MainActor func staleCacheErrorStaysInDetailState() async throws {
        let json = """
        {"id":"i1","share_id":"s1","vault_id":"v1","state":"Active","flags":[],
         "create_time":"2026-01-01T00:00:00Z","modify_time":"2026-01-01T00:00:00Z",
         "content":{"title":"","note":"","item_uuid":"u",
           "content":{"Note":null},"extra_fields":[]}}
        """
        let cliItem = try JSONDecoder().decode(CLIItem.self, from: Data(json.utf8))
        let fetcher: CLIItemFetcher = { _, _ in cliItem }
        let (vm, _) = try makeVM(fetcher: fetcher)
        vm.detailItem = item(fieldKeys: [.extra(path: .topLevel(fieldIndex: 0), name: "Memo", isSensitive: false)])
        vm.copyField(.extra(path: .topLevel(fieldIndex: 0), name: "Memo", isSensitive: false), from: try #require(vm.detailItem))
        await vm.inFlightCopy?.value
        #expect(vm.detailItem != nil)
        #expect(vm.errorMessage == String(localized: "Field no longer available — refresh"))
    }

    @Test(
        "hideDetail cancels in-flight copyField and clears state",
        .timeLimit(.minutes(1))
    )
    @MainActor func hideDetailCancelsInFlightCopy() async throws {
        // Sleep is cancellation-aware; 5 s is unreachable in the happy path
        // but short enough that a cancellation regression surfaces as a slow
        // test rather than a 60-second mystery.
        let slowFetcher: CLIItemFetcher = { _, _ in
            try await Task.sleep(for: .seconds(5))
            throw CancellationError()
        }
        let (vm, clipboard) = try makeVM(fetcher: slowFetcher)
        vm.detailItem = item(fieldKeys: [.extra(path: .topLevel(fieldIndex: 0), name: "Memo", isSensitive: false)])

        vm.copyField(
            .extra(path: .topLevel(fieldIndex: 0), name: "Memo", isSensitive: false),
            from: try #require(vm.detailItem)
        )
        let task = vm.inFlightCopy
        #expect(vm.isActionLoading == true)

        vm.hideDetail()
        await task?.value

        #expect(vm.detailItem == nil)
        #expect(vm.inFlightCopy == nil)
        #expect(vm.isActionLoading == false)
        #expect(clipboard.lastCopiedValue == nil)
    }

    @Test(
        "superseded copyField task cannot publish stale side effects",
        .timeLimit(.minutes(1))
    )
    @MainActor func supersededCopyFieldDoesNotWin() async throws {
        enum TestError: Error { case staleFailure }

        actor Coordinator {
            private var count = 0
            func next() -> Int {
                count += 1
                return count
            }
        }

        let coordinator = Coordinator()
        let firstStarted = AsyncStream<Void>.makeStream()
        let allowFirstToFinish = AsyncStream<Void>.makeStream()
        let secondStarted = AsyncStream<Void>.makeStream()
        let dismissTracker = DismissTracker()

        let secondJSON = """
        {"id":"i1","share_id":"s1","vault_id":"v1","state":"Active","flags":[],
         "create_time":"2026-01-01T00:00:00Z","modify_time":"2026-01-01T00:00:00Z",
         "content":{"title":"","note":"","item_uuid":"u",
           "content":{"CreditCard":{"cardholder_name":"","card_type":"","number":"",
             "verification_number":"","expiration_date":"","pin":"<<FAKE_PIN>>"}},
           "extra_fields":[]}}
        """
        let secondItem = try JSONDecoder().decode(CLIItem.self, from: Data(secondJSON.utf8))

        let fetcher: CLIItemFetcher = { _, _ in
            let call = await coordinator.next()
            if call == 1 {
                firstStarted.continuation.yield(())
                for await _ in allowFirstToFinish.stream { break }
                throw TestError.staleFailure
            } else {
                secondStarted.continuation.yield(())
                return secondItem
            }
        }

        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try db.upsertVaults([PassVault(id: "s1", name: "Personal")])
        let clipboard = ClipboardManager(autoClearSeconds: 0)
        let vm = QuickAccessViewModel(
            searchService: SearchService(databaseManager: db),
            cliService: PassCLIService(),
            clipboardManager: clipboard,
            onDismiss: { dismissTracker.called = true },
            fetchItem: fetcher
        )

        let item = creditCardItem(fieldKeys: [.cardCVV, .cardPIN])
        vm.detailItem = item

        vm.copyField(.cardCVV, from: item)
        var firstIterator = firstStarted.stream.makeAsyncIterator()
        _ = await firstIterator.next()

        vm.copyField(.cardPIN, from: item)
        var secondIterator = secondStarted.stream.makeAsyncIterator()
        _ = await secondIterator.next()

        allowFirstToFinish.continuation.finish()
        await vm.inFlightCopy?.value
        await Task.yield()

        #expect(clipboard.lastCopiedValue == "<<FAKE_PIN>>")
        #expect(vm.errorMessage == nil)
        #expect(dismissTracker.called)
        #expect(vm.isActionLoading == false)
        #expect(vm.inFlightCopy == nil)
    }

    @Test(
        "rapid double copyField — second task finishes cleanly without state clobber",
        .timeLimit(.minutes(1))
    )
    @MainActor func rapidDoubleCopyField() async throws {
        let cvvValue = "<<FAKE_CVV>>"
        let pinValue = "<<FAKE_PIN>>"
        let json = """
        {"id":"i","share_id":"s","vault_id":"v","state":"Active","flags":[],
         "create_time":"2026-01-01T00:00:00Z","modify_time":"2026-01-01T00:00:00Z",
         "content":{"title":"","note":"","item_uuid":"u",
           "content":{"CreditCard":{"cardholder_name":"","card_type":"","number":"",
             "verification_number":"\(cvvValue)","expiration_date":"","pin":"\(pinValue)"}},
           "extra_fields":[]}}
        """
        let cliItem = try JSONDecoder().decode(CLIItem.self, from: Data(json.utf8))

        // First invocation (task1) sleeps until cancellation propagates.
        // Second invocation (task2) signals start, then blocks on a release
        // stream so the test can observe mid-flight state deterministically.
        actor Coordinator {
            private var count = 0
            func next() -> Int {
                count += 1
                return count
            }
        }
        let coord = Coordinator()
        let task2Start = AsyncStream<Void>.makeStream()
        let task2Release = AsyncStream<Void>.makeStream()

        let fetcher: CLIItemFetcher = { _, _ in
            let n = await coord.next()
            if n == 1 {
                // task1: cancelled mid-sleep. 5 s is unreachable in the happy
                // path; the .timeLimit trait backs us up.
                try await Task.sleep(for: .seconds(5))
            } else {
                task2Start.continuation.yield(())
                for await _ in task2Release.stream { break }
            }
            return cliItem
        }

        let (vm, clipboard) = try makeVM(fetcher: fetcher)
        vm.detailItem = creditCardItem(fieldKeys: [.cardCVV, .cardPIN])

        vm.copyField(.cardCVV, from: try #require(vm.detailItem))
        // Ordering yield: guarantees task1 is scheduled and has advanced
        // past its fetcher call (taking count == 1) before task2 is created.
        // Without this, scheduling could put task2 first and the coordinator
        // would swap which task is "slow" vs "fast".
        try await Task.sleep(for: .milliseconds(50))
        vm.copyField(.cardPIN, from: try #require(vm.detailItem))

        // Deterministic observation: wait for task2 to signal it has entered
        // the fetcher body. At this point task1 has been cancelled and its
        // defer has had a chance to run (either already, or in the pending
        // MainActor queue behind this await).
        var iter = task2Start.stream.makeAsyncIterator()
        _ = await iter.next()
        // One more yield to drain any still-pending task1 defer onto MainActor
        // before we read shared state.
        await Task.yield()

        #expect(
            vm.isActionLoading == true,
            "task1's defer must not clear isActionLoading while task2 is still running"
        )
        #expect(vm.inFlightCopy != nil)

        // Release task2 to complete its fetch.
        task2Release.continuation.finish()
        await vm.inFlightCopy?.value

        #expect(clipboard.lastCopiedValue == pinValue)
        #expect(vm.isActionLoading == false)
        #expect(vm.inFlightCopy == nil)
    }

    @Test("Shift+Return on password action presents validated large type")
    @MainActor func largeTypeShortcutPresentsPassword() async throws {
        UserDefaults.standard.set(36, forKey: DefaultsKey.showLargeTypeKeyCode)
        UserDefaults.standard.set(Int(NSEvent.ModifierFlags.shift.rawValue), forKey: DefaultsKey.showLargeTypeModifiers)
        let json = """
        {"id":"i1","share_id":"s1","vault_id":"s1","state":"Active","flags":[],
         "create_time":"2026-01-01T00:00:00Z","modify_time":"2026-01-01T00:00:00Z",
         "content":{"title":"","note":"","item_uuid":"u",
           "content":{"Login":{"email":"user@example.com","password":"A1@z","username":"user","urls":[],"totp_uri":"","passkeys":[]}},
           "extra_fields":[]}}
        """
        let cliItem = try JSONDecoder().decode(CLIItem.self, from: Data(json.utf8))
        let fetcher: CLIItemFetcher = { _, _ in cliItem }
        var presented: LargeTypeDisplay?
        let (vm, _) = try makeVM(fetcher: fetcher, presentLargeType: { presented = $0 })
        vm.detailItem = item(fieldKeys: [.email])
        vm.selectedRowIndex = 1

        let handled = vm.handleKeyDown(keyCode: 36, modifiers: [.shift])
        await vm.inFlightLargeType?.value

        #expect(handled)
        #expect(presented?.value == "A1@z")
        #expect(vm.errorMessage == nil)
    }

    @Test("Large Type request cancels an in-flight copy task")
    @MainActor func largeTypeCancelsInFlightCopy() async throws {
        UserDefaults.standard.set(36, forKey: DefaultsKey.showLargeTypeKeyCode)
        UserDefaults.standard.set(Int(NSEvent.ModifierFlags.shift.rawValue), forKey: DefaultsKey.showLargeTypeModifiers)

        let json = """
        {"id":"i1","share_id":"s1","vault_id":"s1","state":"Active","flags":[],
         "create_time":"2026-01-01T00:00:00Z","modify_time":"2026-01-01T00:00:00Z",
         "content":{"title":"","note":"","item_uuid":"u",
           "content":{"Login":{"email":"user@example.com","password":"hunter2","username":"u","urls":[],"totp_uri":"","passkeys":[]}},
           "extra_fields":[]}}
        """
        let cliItem = try JSONDecoder().decode(CLIItem.self, from: Data(json.utf8))
        let fetcher: CLIItemFetcher = { _, _ in
            try await Task.sleep(for: .milliseconds(50))
            return cliItem
        }

        var presented: LargeTypeDisplay?
        let (vm, _) = try makeVM(fetcher: fetcher, presentLargeType: { presented = $0 })
        vm.detailItem = item(fieldKeys: [.email])
        vm.selectedRowIndex = 1

        // Kick off a copy task (resolves after 50ms)
        vm.copyField(.email, from: try #require(vm.detailItem))
        #expect(vm.inFlightCopy != nil)

        // Immediately request Large Type — should cancel the copy
        _ = vm.handleKeyDown(keyCode: 36, modifiers: [.shift])
        #expect(vm.inFlightCopy == nil)

        await vm.inFlightLargeType?.value

        #expect(presented != nil)
        #expect(vm.inFlightLargeType == nil)
        #expect(vm.isActionLoading == false)
    }

    @Test("Open in Browser row is rejected for large type")
    @MainActor func largeTypeRejectsOpenURL() async throws {
        UserDefaults.standard.set(36, forKey: DefaultsKey.showLargeTypeKeyCode)
        UserDefaults.standard.set(Int(NSEvent.ModifierFlags.shift.rawValue), forKey: DefaultsKey.showLargeTypeModifiers)
        let (vm, _) = try makeVM()
        vm.detailItem = item(fieldKeys: [.email])
        let rows = vm.rows(for: try #require(vm.detailItem))
        vm.selectedRowIndex = try #require(rows.firstIndex {
            if case .namedAction(let action, _, _) = $0 { return action == .openURL }
            return false
        })

        _ = vm.handleKeyDown(keyCode: 36, modifiers: [.shift])
        await vm.inFlightLargeType?.value

        #expect(vm.errorMessage == String(localized: "This row can't be shown in Large Type"))
    }
}
