import Testing
import Foundation
import AppKit
@testable import Quick_Access_for_Pass

private final class ActivityCounter {
    private(set) var count = 0
    func increment() { count += 1 }
    func reset() { count = 0 }
}

private func makeDefaults(_ name: String) -> UserDefaults {
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@MainActor
private func makeViewModel(
    counter: ActivityCounter,
    defaults: UserDefaults = makeDefaults(#function)
) throws -> (QuickAccessViewModel, DatabaseManager) {
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
    ]
    try db.upsertItems(items)
    let vm = QuickAccessViewModel(
        searchService: SearchService(databaseManager: db),
        cliService: PassCLIService(),
        clipboardManager: ClipboardManager(autoClearSeconds: 0),
        onDismiss: {},
        onActivity: { [weak counter] in counter?.increment() },
        defaults: defaults
    )
    vm.performSearch(query: "git")
    return (vm, db)
}

@Suite("QuickAccessViewModel — Activity Signal")
@MainActor
struct QuickAccessViewModelActivityTests {

    @Test func showDetailFiresActivity() throws {
        let counter = ActivityCounter()
        let (vm, _) = try makeViewModel(counter: counter)
        vm.showDetail()
        #expect(counter.count == 1)
    }

    @Test func hideDetailFiresActivity() throws {
        let counter = ActivityCounter()
        let (vm, _) = try makeViewModel(counter: counter)
        vm.showDetail()
        counter.reset()
        vm.hideDetail()
        #expect(counter.count == 1)
    }

    @Test func moveSelectionFiresActivity() throws {
        let counter = ActivityCounter()
        let (vm, _) = try makeViewModel(counter: counter)
        counter.reset()
        vm.moveSelection(by: 1)
        #expect(counter.count == 1)
    }

    @Test func moveRowSelectionFiresActivity() throws {
        let counter = ActivityCounter()
        let (vm, _) = try makeViewModel(counter: counter)
        vm.showDetail()
        counter.reset()
        vm.moveRowSelection(by: 1)
        #expect(counter.count == 1)
    }

    @Test func handleEnterNoDetailFiresActivityTwice() throws {
        // Path: handleEnter (+1) -> handleAction(defaultAction, ...) (+1) = 2.
        let counter = ActivityCounter()
        let (vm, _) = try makeViewModel(counter: counter)
        counter.reset()
        vm.handleEnter()
        #expect(counter.count == 2)
    }

    @Test func handleActionFiresActivityOnce() throws {
        let counter = ActivityCounter()
        let (vm, _) = try makeViewModel(counter: counter)
        let item = try #require(vm.items.first)
        counter.reset()
        vm.handleAction(.copyUsername, for: item)
        #expect(counter.count == 1)
    }

    @Test func showSelectedRowInLargeTypeFiresActivity() throws {
        let counter = ActivityCounter()
        let (vm, _) = try makeViewModel(counter: counter)
        vm.showDetail()
        counter.reset()
        vm.showSelectedRowInLargeType()
        #expect(counter.count == 1)
    }

    @Test func matchedHandleKeyDownFiresActivityTwice() throws {
        // Path: handleKeyDown (+1) -> handleAction (+1) = 2.
        let counter = ActivityCounter()
        let defaults = makeDefaults(#function)
        defaults.set(0x08, forKey: DefaultsKey.copyUsernameKeyCode) // Carbon keyCode 8 = "C"
        defaults.set(Int(NSEvent.ModifierFlags.command.rawValue),
                     forKey: DefaultsKey.copyUsernameModifiers)
        let (vm, _) = try makeViewModel(counter: counter, defaults: defaults)
        counter.reset()
        let handled = vm.handleKeyDown(keyCode: 0x08, modifiers: .command)
        #expect(handled == true)
        #expect(counter.count == 2)
    }

    @Test func unmatchedHandleKeyDownDoesNotFireActivity() throws {
        let counter = ActivityCounter()
        let (vm, _) = try makeViewModel(counter: counter)
        counter.reset()
        let handled = vm.handleKeyDown(keyCode: 0xFFFF, modifiers: [])
        #expect(handled == false)
        #expect(counter.count == 0)
    }

    @Test func programmaticSearchClearDoesNotFireActivity() async throws {
        let counter = ActivityCounter()
        let defaults = makeDefaults(#function)
        defaults.set(0.01, forKey: DefaultsKey.searchClearTimeout)
        let (vm, _) = try makeViewModel(counter: counter, defaults: defaults)

        vm.searchQuery = "github"
        counter.reset()
        vm.scheduleSearchClear()
        await vm.awaitPendingSearchClear()
        #expect(vm.searchQuery.isEmpty)
        #expect(counter.count == 0)
    }
}
