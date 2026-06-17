import Testing
import Foundation
@testable import Quick_Access_for_Pass

@MainActor
private func makeSearchFocusViewModelWithDetail() throws -> QuickAccessViewModel {
    let database = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
    try database.upsertVaults([PassVault(id: "s1", name: "Personal")])
    try database.upsertItems([
        PassItem(
            id: "1",
            vaultId: "s1",
            title: "GitHub",
            itemType: .login,
            subtitle: "user@github.com",
            url: "https://github.com",
            hasTOTP: true,
            state: "Active",
            createTime: Date(),
            modifyTime: Date(),
            useCount: 5,
            lastUsedAt: Date()
        ),
    ])

    let viewModel = QuickAccessViewModel(
        searchService: SearchService(databaseManager: database),
        cliService: PassCLIService(),
        clipboardManager: ClipboardManager(autoClearSeconds: 0),
        onDismiss: {}
    )
    viewModel.performSearch(query: "git")
    viewModel.showDetail()
    return viewModel
}

@Suite("Search focus requests")
@MainActor
struct SearchFocusRequestTests {
    @Test func unlockedPanelPresentationRequestsSearchFocus() {
        let defaults = UserDefaults(suiteName: "SearchFocusRequestTests.unlocked")!
        defaults.removePersistentDomain(forName: "SearchFocusRequestTests.unlocked")
        defaults.set(false, forKey: DefaultsKey.lockoutEnabled)

        let delegate = AppDelegate()
        delegate.testDefaults = defaults
        let initialRequestID = delegate.searchFocusRequestID

        delegate.requestSearchFocusIfNeeded()

        #expect(delegate.searchFocusRequestID != initialRequestID)
        #expect(delegate.searchFocusRequestID != nil)
    }

    @Test func lockedPanelPresentationDoesNotRequestSearchFocus() {
        let defaults = UserDefaults(suiteName: "SearchFocusRequestTests.locked")!
        defaults.removePersistentDomain(forName: "SearchFocusRequestTests.locked")
        defaults.set(true, forKey: DefaultsKey.lockoutEnabled)

        let delegate = AppDelegate()
        delegate.testDefaults = defaults
        delegate.lastActivityAt = nil
        let initialRequestID = delegate.searchFocusRequestID

        delegate.requestSearchFocusIfNeeded()

        #expect(delegate.searchFocusRequestID == initialRequestID)
    }

    @Test func detailPanelPresentationDoesNotRequestSearchFocus() throws {
        let defaults = UserDefaults(suiteName: "SearchFocusRequestTests.detail")!
        defaults.removePersistentDomain(forName: "SearchFocusRequestTests.detail")
        defaults.set(false, forKey: DefaultsKey.lockoutEnabled)

        let delegate = AppDelegate()
        delegate.testDefaults = defaults
        delegate.viewModel = try makeSearchFocusViewModelWithDetail()
        let initialRequestID = delegate.searchFocusRequestID

        delegate.requestSearchFocusIfNeeded()

        #expect(delegate.searchFocusRequestID == initialRequestID)
    }
}
