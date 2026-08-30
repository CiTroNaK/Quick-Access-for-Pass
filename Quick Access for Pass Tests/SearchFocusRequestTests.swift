import AppKit
import Foundation
import Testing
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

@MainActor
private final class SimulatedKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
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

    @Test("Current foreign key window hides the panel")
    func currentForeignKeyWindowHidesPanel() {
        let delegate = AppDelegate()
        let panelController = PanelController()
        let foreignWindow = SimulatedKeyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { panelController.hide(ignoringBlock: true) }

        delegate.panelController = panelController
        delegate.keyWindowProvider = { foreignWindow }
        panelController.windowForPresentation.orderFront(nil)

        delegate.handleWindowDidBecomeKey(foreignWindow)

        #expect(!panelController.isVisible)
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

    @Test("User-opened locked panel requests search focus after unlock")
    func userOpenedLockedPanelRequestsSearchFocusAfterUnlock() {
        let suiteName = "SearchFocusRequestTests.userOpenedUnlock"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: DefaultsKey.lockoutEnabled)

        let delegate = AppDelegate()
        let panelController = PanelController()
        defer {
            panelController.hide(ignoringBlock: true)
            defaults.removePersistentDomain(forName: suiteName)
        }

        delegate.testDefaults = defaults
        delegate.lastActivityAt = nil
        delegate.panelController = panelController
        panelController.show()
        let initialRequestID = delegate.searchFocusRequestID
        #expect(delegate.beginPanelUnlock() != nil)

        delegate.completePanelUnlock()

        #expect(panelController.isVisible)
        #expect(delegate.searchFocusRequestID != initialRequestID)
    }

    @Test("Queued key-window event during Touch ID does not hide a user-opened panel")
    func queuedKeyWindowEventDuringUnlockDoesNotHideUserPanel() async throws {
        let suiteName = "SearchFocusRequestTests.queuedKeyWindowEvent"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: DefaultsKey.lockoutEnabled)

        let delegate = AppDelegate()
        let panelController = PanelController()
        let foreignWindow = SimulatedKeyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer {
            panelController.hide(ignoringBlock: true)
            defaults.removePersistentDomain(forName: suiteName)
        }

        delegate.testDefaults = defaults
        delegate.lastActivityAt = nil
        delegate.panelController = panelController
        delegate.keyWindowProvider = { foreignWindow }
        let hideAttempts = TestCallCounter()
        panelController.shouldBlockHide = {
            hideAttempts.record()
            return delegate.isUnlockInFlight
        }
        panelController.windowForPresentation.orderFront(nil)
        let initialRequestID = delegate.searchFocusRequestID
        let attemptID = try #require(delegate.beginPanelUnlock())

        delegate.handleWindowDidBecomeKeyNotification(
            Notification(name: NSWindow.didBecomeKeyNotification, object: foreignWindow)
        )
        delegate.completePanelUnlock()
        delegate.endPanelUnlock(attemptID)

        let didAttemptBlockedHide = await waitForTestCondition {
            hideAttempts.count >= 1
        }
        #expect(didAttemptBlockedHide)
        #expect(panelController.isVisible)
        #expect(delegate.searchFocusRequestID != initialRequestID)
    }

    @Test("Delayed Touch ID key-window event after unlock does not hide a user-opened panel")
    func delayedKeyWindowEventAfterUnlockDoesNotHideUserPanel() throws {
        let suiteName = "SearchFocusRequestTests.delayedKeyWindowEvent"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: DefaultsKey.lockoutEnabled)

        let delegate = AppDelegate()
        let panelController = PanelController()
        let foreignWindow = SimulatedKeyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer {
            panelController.hide(ignoringBlock: true)
            defaults.removePersistentDomain(forName: suiteName)
        }

        delegate.testDefaults = defaults
        delegate.lastActivityAt = nil
        delegate.panelController = panelController
        panelController.shouldBlockHide = { delegate.isUnlockInFlight }
        panelController.windowForPresentation.orderFront(nil)

        let attemptID = try #require(delegate.beginPanelUnlock())
        delegate.completePanelUnlock()
        delegate.endPanelUnlock(attemptID)
        #expect(!panelController.isShowingTransition)
        #expect(foreignWindow.isKeyWindow)
        #expect(NSApp.keyWindow !== foreignWindow)

        delegate.handleWindowDidBecomeKey(foreignWindow)

        #expect(panelController.isVisible)
    }

    @Test("Unrelated auth success does not focus a panel with unlock in flight")
    func unrelatedAuthSuccessDoesNotFocusPanelUnlock() {
        let suiteName = "SearchFocusRequestTests.unrelatedAuth"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: DefaultsKey.lockoutEnabled)

        let delegate = AppDelegate()
        let panelController = PanelController()
        defer {
            panelController.hide(ignoringBlock: true)
            defaults.removePersistentDomain(forName: suiteName)
        }

        delegate.testDefaults = defaults
        delegate.lastActivityAt = nil
        delegate.panelController = panelController
        panelController.show()
        let initialRequestID = delegate.searchFocusRequestID
        #expect(delegate.beginPanelUnlock() != nil)

        delegate.resetAuthTimestamp()

        #expect(panelController.isVisible)
        #expect(delegate.searchFocusRequestID == initialRequestID)
    }

    @Test("SSH-triggered locked panel hides after unlock without focusing search")
    func sshTriggeredLockedPanelHidesAfterUnlockWithoutFocusingSearch() async {
        let suiteName = "SearchFocusRequestTests.sshTriggeredUnlock"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: DefaultsKey.lockoutEnabled)

        let delegate = AppDelegate()
        let panelController = PanelController()
        let timeout = ManualUnlockWaiterTimeout()
        defer {
            timeout.fireAll()
            panelController.hide(ignoringBlock: true)
            defaults.removePersistentDomain(forName: suiteName)
        }

        delegate.testDefaults = defaults
        delegate.lastActivityAt = nil
        delegate.panelController = panelController
        delegate.waitForUnlockTimeout = { _ in await timeout.wait() }
        let initialRequestID = delegate.searchFocusRequestID

        async let unlocked = delegate.showPanelAndWaitForUnlock()
        let didRegisterWaiter = await waitForTestCondition {
            !delegate.pendingUnlockWaiters.isEmpty && timeout.pendingCount >= 1
        }
        guard didRegisterWaiter else {
            Issue.record("SSH-triggered unlock waiter and timeout did not register.")
            delegate.cancelPanelUnlock()
            timeout.fireAll()
            return
        }
        #expect(delegate.beginPanelUnlock() != nil)

        delegate.resetAuthTimestamp()

        #expect(await unlocked)
        let didHide = await waitForTestCondition {
            panelController.isVisible == false
        }
        #expect(didHide)
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
