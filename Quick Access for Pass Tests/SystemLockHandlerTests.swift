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
        let delegate = AppDelegate()
        delegate.testDefaults = defaults
        let viewModel = QuickAccessViewModel(
            searchService: SearchService(databaseManager: db),
            cliService: PassCLIService(),
            clipboardManager: clipboard,
            onDismiss: {},
            secretReleaseGuard: delegate.secretReleaseGuard
        )
        viewModel.searchQuery = "git"
        viewModel.performSearch(query: "git")
        viewModel.errorMessage = "Failed"
        clipboard.copy("secret")

        delegate.viewModel = viewModel
        delegate.resetAuthTimestamp()

        return (delegate, viewModel, pasteboard)
    }

    @Test func disabledSettingPreservesAppLockStateButClearsOwnedClipboard() throws {
        let (delegate, viewModel, pasteboard) = try makeFixture(lockOnSystemLock: false)

        delegate.handleSystemLockEvent()

        #expect(delegate.isLocked == false)
        #expect(viewModel.searchQuery == "git")
        #expect(viewModel.errorMessage == "Failed")
        let value = pasteboard.string(forType: .string)
        #expect(value == nil || value == "")
    }

    @Test func disabledSettingRevokesBlockedSecretActionWithoutChangingLockPolicy() async throws {
        let (delegate, viewModel, pasteboard) = try makeFixture(lockOnSystemLock: false)
        let gate = OfflineTestGate()
        let resolver = SystemLockBlockingResolver(gate: gate)
        let guardedViewModel = QuickAccessViewModel(
            searchService: viewModel.searchService,
            cliService: PassCLIService(),
            clipboardManager: ClipboardManager(autoClearSeconds: 0, pasteboard: pasteboard),
            onDismiss: {},
            secretResolver: resolver,
            secretReleaseGuard: delegate.secretReleaseGuard
        )
        delegate.viewModel = guardedViewModel
        pasteboard.clearContents()
        let item = offlineTestMetadata(id: "1", vaultID: "s1")
        guardedViewModel.handleAction(.copyPassword, for: item)
        do {
            try await gate.waitUntilEntered()
            delegate.handleSystemLockEvent()
            await gate.open()
            await guardedViewModel.inFlightCopy?.value
            #expect(delegate.isLocked == false)
            #expect(delegate.testDefaults?.bool(forKey: DefaultsKey.lockOnSystemLock) == false)
            #expect(pasteboard.string(forType: .string) == nil)
        } catch {
            await gate.open()
            throw error
        }
    }

    @Test func forceLockRevokesTheSharedReleaseGeneration() throws {
        let (delegate, _, _) = try makeFixture(lockOnSystemLock: false)
        let token = delegate.secretReleaseGuard.capture()

        delegate.forceLock()

        #expect(delegate.isLocked)
        #expect(!delegate.secretReleaseGuard.isCurrent(token))
        #expect(delegate.testDefaults?.bool(forKey: DefaultsKey.lockOnSystemLock) == false)
    }

    @Test func forceLockStopsABlockedSecretAction() async throws {
        let (delegate, viewModel, pasteboard) = try makeFixture(lockOnSystemLock: false)
        let gate = OfflineTestGate()
        let guardedViewModel = QuickAccessViewModel(
            searchService: viewModel.searchService, cliService: PassCLIService(),
            clipboardManager: ClipboardManager(autoClearSeconds: 0, pasteboard: pasteboard), onDismiss: {},
            secretResolver: SystemLockBlockingResolver(gate: gate), secretReleaseGuard: delegate.secretReleaseGuard
        )
        delegate.viewModel = guardedViewModel
        pasteboard.clearContents()
        guardedViewModel.handleAction(.copyPassword, for: offlineTestMetadata(id: "1", vaultID: "s1"))
        do {
            try await gate.waitUntilEntered()
            let task = try #require(guardedViewModel.inFlightCopy)
            delegate.forceLock()
            await gate.open()
            await task.value
            #expect(delegate.isLocked)
            #expect(pasteboard.string(forType: .string) == nil)
        } catch {
            await gate.open()
            throw error
        }
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

private actor SystemLockBlockingResolver: SecretItemResolving {
    let gate: OfflineTestGate

    init(gate: OfflineTestGate) { self.gate = gate }

    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<CLIItem> {
        try? await gate.wait()
        return ResolvedSecret(value: try offlineTestCLIItem(id: itemId, vaultID: vaultId, shareID: shareId, password: "system-lock-secret"), offlineCapability: nil)
    }

    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<String> {
        try? await gate.wait()
        return ResolvedSecret(value: "000000", offlineCapability: nil)
    }
}
