import AppKit
import Foundation
@preconcurrency import LocalAuthentication
import Testing
@testable import Quick_Access_for_Pass

@MainActor
final class ManualUnlockWaiterTimeout {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var resumesFutureWaiters = false

    var pendingCount: Int { continuations.count }

    func wait() async {
        guard !resumesFutureWaiters else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func fire(at index: Int = 0) {
        guard continuations.indices.contains(index) else {
            Issue.record("No timeout suspension exists at index \(index).")
            return
        }
        continuations.remove(at: index).resume()
    }

    func fireAll() {
        resumesFutureWaiters = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

@Suite("AppDelegate unlock waiters")
@MainActor
struct UnlockWaiterTests {

    @Test("Locked panel disables the system password fallback during Touch ID")
    func lockedPanelDisablesSystemPasswordFallback() {
        let context = LockedView.makeAuthenticationContext()

        #expect(context.localizedFallbackTitle == "")
        #expect(context.touchIDAuthenticationAllowableReuseDuration == 10)
    }

    @Test func resetAuthTimestampResumesWaiterAndRefreshesActivity() async throws {
        let delegate = AppDelegate()
        let timeout = ManualUnlockWaiterTimeout()
        let suiteName = "UnlockWaiterTests.resumesWaiterAndRefreshesActivity"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: DefaultsKey.lockoutEnabled)
        defer {
            timeout.fireAll()
            defaults.removePersistentDomain(forName: suiteName)
        }
        delegate.testDefaults = defaults
        delegate.lastAuthenticatedAt = Date(timeIntervalSince1970: 100)
        delegate.lastActivityAt = Date(timeIntervalSince1970: 200)
        delegate.waitForUnlockTimeout = { _ in await timeout.wait() }

        async let waited = delegate.showPanelAndWaitForUnlock()

        // Deterministic: yield until the child Task has registered its
        // continuation, with a finite bound so a regression fails instead of hanging.
        let didRegisterWaiter = await waitForTestCondition {
            !delegate.pendingUnlockWaiters.isEmpty && timeout.pendingCount >= 1
        }
        guard didRegisterWaiter else {
            Issue.record("Unlock waiter and timeout did not register.")
            delegate.cancelPanelUnlock()
            timeout.fireAll()
            return
        }

        delegate.resetAuthTimestamp()

        #expect(await waited == true)
        let refreshedAuth = try #require(delegate.lastAuthenticatedAt)
        let refreshedActivity = try #require(delegate.lastActivityAt)
        #expect(refreshedAuth > Date(timeIntervalSince1970: 100))
        #expect(refreshedActivity > Date(timeIntervalSince1970: 200))
        #expect(abs(refreshedAuth.timeIntervalSince(refreshedActivity)) < 0.1)
    }

    @Test("Attaching an unlock waiter to a visible panel preserves its session")
    func visiblePanelUnlockWaitPreservesPanelSession() async {
        let suiteName = "UnlockWaiterTests.visiblePanelSession"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: DefaultsKey.lockoutEnabled)

        let previousApplication = NSRunningApplication.current
        var frontmostLookupCount = 0
        var activatedProcessIdentifiers: [pid_t] = []
        let panelController = PanelController(
            frontmostApplication: {
                frontmostLookupCount += 1
                return frontmostLookupCount == 1 ? previousApplication : nil
            },
            activateApplication: {
                activatedProcessIdentifiers.append($0.processIdentifier)
            }
        )
        let timeout = ManualUnlockWaiterTimeout()
        defer {
            timeout.fireAll()
            panelController.hide(ignoringBlock: true)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let delegate = AppDelegate()
        delegate.testDefaults = defaults
        delegate.lastActivityAt = nil
        delegate.panelController = panelController
        delegate.waitForUnlockTimeout = { _ in await timeout.wait() }
        panelController.show()

        async let unlocked = delegate.showPanelAndWaitForUnlock()
        let didRegisterWaiter = await waitForTestCondition {
            !delegate.pendingUnlockWaiters.isEmpty && timeout.pendingCount >= 1
        }
        guard didRegisterWaiter else {
            Issue.record("Visible-panel waiter and timeout did not register.")
            delegate.cancelPanelUnlock()
            timeout.fireAll()
            return
        }

        #expect(frontmostLookupCount == 1)
        #expect(delegate.beginPanelUnlock() != nil)
        delegate.resetAuthTimestamp()
        #expect(await unlocked)

        panelController.hide()

        #expect(activatedProcessIdentifiers == [previousApplication.processIdentifier])
    }

    @Test("System-created panel remains visible while another unlock waiter is pending")
    func systemPanelRemainsVisibleForPendingWaiter() async {
        let suiteName = "UnlockWaiterTests.pendingSystemWaiter"
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

        async let longWait = delegate.showPanelAndWaitForUnlock(timeoutSeconds: 5)
        let didRegisterLongWait = await waitForTestCondition {
            delegate.pendingUnlockWaiters.count >= 1 && timeout.pendingCount >= 1
        }
        guard didRegisterLongWait else {
            Issue.record("Long unlock waiter and timeout did not register.")
            delegate.cancelPanelUnlock()
            timeout.fireAll()
            return
        }
        async let shortWait = delegate.showPanelAndWaitForUnlock(timeoutSeconds: 0.01)
        let didRegisterShortWait = await waitForTestCondition {
            delegate.pendingUnlockWaiters.count >= 2 && timeout.pendingCount >= 2
        }
        guard didRegisterShortWait else {
            Issue.record("Short unlock waiter and timeout did not register.")
            delegate.cancelPanelUnlock()
            timeout.fireAll()
            return
        }
        timeout.fire(at: 1)

        #expect(await shortWait == false)
        #expect(delegate.pendingUnlockWaiters.count == 1)
        #expect(delegate.panelShownForLockWait)
        #expect(panelController.isVisible)

        delegate.resetAuthTimestamp()
        timeout.fireAll()

        #expect(await longWait)
        let didHide = await waitForTestCondition {
            panelController.isVisible == false
        }
        #expect(didHide)
    }

    @Test("Panel authentication is single-flight and stale completions cannot hide the panel")
    func panelAuthenticationIsSingleFlight() async {
        let delegate = AppDelegate()
        let panelController = PanelController(activateApplication: { _ in })
        defer { panelController.hide(ignoringBlock: true) }
        delegate.panelController = panelController
        delegate.panelShownForLockWait = true
        panelController.shouldBlockHide = { delegate.isUnlockInFlight }
        panelController.show()

        let firstAttempt = delegate.beginPanelUnlock()
        #expect(firstAttempt != nil)
        #expect(delegate.beginPanelUnlock() == nil)
        guard let firstAttempt else { return }

        delegate.endPanelUnlock(UUID())

        #expect(delegate.isUnlockInFlight)
        #expect(panelController.isVisible)

        delegate.endPanelUnlock(firstAttempt)

        let didHide = await waitForTestCondition {
            panelController.isVisible == false
        }
        #expect(delegate.isUnlockInFlight == false)
        #expect(didHide)
        #expect(delegate.panelShownForLockWait == false)
    }

    @Test("Canceling panel auth denies waiters and hides a system-created panel")
    func cancelingPanelAuthDeniesWaitersAndHidesSystemPanel() async {
        let suiteName = "UnlockWaiterTests.cancelPanelAuth"
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
        let hideAttempts = TestCallCounter()
        panelController.shouldBlockHide = {
            hideAttempts.record()
            return delegate.isUnlockInFlight
        }

        async let unlocked = delegate.showPanelAndWaitForUnlock()
        let didRegisterWaiter = await waitForTestCondition {
            !delegate.pendingUnlockWaiters.isEmpty && timeout.pendingCount >= 1
        }
        guard didRegisterWaiter else {
            Issue.record("Canceled-auth waiter and timeout did not register.")
            delegate.cancelPanelUnlock()
            timeout.fireAll()
            return
        }
        let unlockAttempt = delegate.beginPanelUnlock()
        #expect(unlockAttempt != nil)
        let initialRequestID = delegate.searchFocusRequestID

        delegate.cancelPanelUnlock()

        let cancellationDrainedWaiters = delegate.pendingUnlockWaiters.isEmpty
        #expect(cancellationDrainedWaiters)
        if !cancellationDrainedWaiters {
            timeout.fire()
        }
        #expect(await unlocked == false)
        let didAttemptBlockedHide = await waitForTestCondition {
            hideAttempts.count >= 1
        }
        #expect(didAttemptBlockedHide)
        #expect(panelController.isVisible)
        #expect(delegate.panelShownForLockWait)

        if let unlockAttempt {
            delegate.endPanelUnlock(unlockAttempt)
        }

        let didHide = await waitForTestCondition {
            panelController.isVisible == false
        }
        #expect(didHide)
        #expect(delegate.panelShownForLockWait == false)
        #expect(delegate.searchFocusRequestID == initialRequestID)
    }

    @Test("Final timeout during panel auth hides the system panel after auth completes")
    func finalTimeoutDuringPanelAuthDefersHideUntilPhaseEnds() async {
        let suiteName = "UnlockWaiterTests.timeoutDuringPanelAuth"
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
        let hideAttempts = TestCallCounter()
        panelController.shouldBlockHide = {
            hideAttempts.record()
            return delegate.isUnlockInFlight
        }

        async let unlocked = delegate.showPanelAndWaitForUnlock()
        let didRegisterWaiter = await waitForTestCondition {
            !delegate.pendingUnlockWaiters.isEmpty && timeout.pendingCount >= 1
        }
        guard didRegisterWaiter else {
            Issue.record("In-flight-auth waiter and timeout did not register.")
            delegate.cancelPanelUnlock()
            timeout.fireAll()
            return
        }
        let unlockAttempt = delegate.beginPanelUnlock()
        #expect(unlockAttempt != nil)
        let initialRequestID = delegate.searchFocusRequestID
        timeout.fire()

        #expect(await unlocked == false)
        let didAttemptBlockedHide = await waitForTestCondition {
            hideAttempts.count >= 1
        }
        #expect(didAttemptBlockedHide)
        #expect(panelController.isVisible)
        #expect(delegate.panelShownForLockWait)

        delegate.completePanelUnlock()
        if let unlockAttempt {
            delegate.endPanelUnlock(unlockAttempt)
        }

        let didHide = await waitForTestCondition {
            panelController.isVisible == false
        }
        #expect(didHide)
        #expect(delegate.panelShownForLockWait == false)
        #expect(delegate.searchFocusRequestID == initialRequestID)
    }

    @Test func timeoutResumesWaiterWithFalse() async {
        let delegate = AppDelegate()
        let timeout = ManualUnlockWaiterTimeout()
        defer { timeout.fireAll() }
        let defaults = UserDefaults(suiteName: "UnlockWaiterTests.timeout")!
        defaults.removePersistentDomain(forName: "UnlockWaiterTests.timeout")
        defaults.set(true, forKey: DefaultsKey.lockoutEnabled)
        delegate.testDefaults = defaults
        delegate.lastActivityAt = nil
        delegate.waitForUnlockTimeout = { _ in await timeout.wait() }

        async let result = delegate.showPanelAndWaitForUnlock(timeoutSeconds: 0.25)
        let didRegisterWaiter = await waitForTestCondition {
            !delegate.pendingUnlockWaiters.isEmpty && timeout.pendingCount >= 1
        }
        guard didRegisterWaiter else {
            Issue.record("Timeout waiter did not register.")
            delegate.cancelPanelUnlock()
            timeout.fireAll()
            return
        }
        timeout.fire()

        #expect(await result == false)
    }
}
