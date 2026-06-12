import AppKit
import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("System lock handler")
@MainActor
struct SystemLockHandlerTests {
    private func makeDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeFixture(
        lockOnSystemLock: Bool,
        name: String = UUID().uuidString
    ) throws -> (AppDelegate, QuickAccessViewModel, NSPasteboard) {
        let defaults = makeDefaults(name)
        defaults.set(lockOnSystemLock, forKey: DefaultsKey.lockOnSystemLock)
        defaults.set(false, forKey: DefaultsKey.lockoutEnabled)

        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try db.upsertVaults([PassVault(id: "s1", name: "Personal")])
        try db.upsertItems([
            PassItem(
                id: "1",
                vaultId: "s1",
                title: "GitHub",
                itemType: .login,
                subtitle: "user@github.com",
                url: "https://github.com",
                hasTOTP: false,
                state: "Active",
                createTime: Date(),
                modifyTime: Date(),
                useCount: 0,
                lastUsedAt: nil
            ),
        ])

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("system-lock-handler-\(name)"))
        let clipboard = ClipboardManager(autoClearSeconds: 0, pasteboard: pasteboard)
        let viewModel = QuickAccessViewModel(
            searchService: SearchService(databaseManager: db),
            cliService: PassCLIService(),
            clipboardManager: clipboard,
            onDismiss: {}
        )
        viewModel.searchQuery = "git"
        viewModel.performSearch(query: "git")
        viewModel.errorMessage = "Failed"
        clipboard.copy("secret")

        let delegate = AppDelegate()
        delegate.testDefaults = defaults
        delegate.viewModel = viewModel
        delegate.resetAuthTimestamp()

        return (delegate, viewModel, pasteboard)
    }

    @Test func disabledSettingIgnoresSystemLockEvent() throws {
        let (delegate, viewModel, pasteboard) = try makeFixture(lockOnSystemLock: false)

        delegate.handleSystemLockEvent()

        #expect(delegate.isLocked == false)
        #expect(viewModel.searchQuery == "git")
        #expect(viewModel.errorMessage == "Failed")
        #expect(pasteboard.string(forType: .string) == "secret")
    }

    @Test func enabledSettingForcesLockAndClearsSensitiveState() throws {
        let (delegate, viewModel, pasteboard) = try makeFixture(lockOnSystemLock: true)

        delegate.handleSystemLockEvent()

        #expect(delegate.isLocked)
        #expect(viewModel.searchQuery == "")
        #expect(viewModel.items.isEmpty)
        #expect(viewModel.errorMessage == nil)
        let value = pasteboard.string(forType: .string)
        #expect(value == nil || value == "")
    }

    @Test func enabledSettingPreservesExternallyChangedClipboard() throws {
        let (delegate, _, pasteboard) = try makeFixture(lockOnSystemLock: true)
        pasteboard.clearContents()
        pasteboard.setString("user-value", forType: .string)

        delegate.handleSystemLockEvent()

        #expect(pasteboard.string(forType: .string) == "user-value")
    }
}
