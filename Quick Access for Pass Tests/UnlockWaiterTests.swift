import Testing
import Foundation
@testable import Quick_Access_for_Pass

@Suite("AppDelegate unlock waiters")
@MainActor
struct UnlockWaiterTests {

    @Test func resetAuthTimestampResumesWaiter() async {
        let delegate = AppDelegate()
        let defaults = UserDefaults(suiteName: "UnlockWaiterTests.resumesWaiter")!
        defaults.removePersistentDomain(forName: "UnlockWaiterTests.resumesWaiter")
        defaults.set(true, forKey: DefaultsKey.lockoutEnabled)
        delegate.testDefaults = defaults
        delegate.lastAuthenticatedAt = nil

        async let waited = delegate.showPanelAndWaitForUnlock()

        // Deterministic: spin until the child Task has registered its
        // continuation. Avoids reliance on wall-clock sleeps.
        while delegate.pendingUnlockWaiters.isEmpty {
            await Task.yield()
        }

        delegate.resetAuthTimestamp()

        #expect(await waited == true)
    }

    @Test func timeoutResumesWaiterWithFalse() async {
        let delegate = AppDelegate()
        let defaults = UserDefaults(suiteName: "UnlockWaiterTests.timeout")!
        defaults.removePersistentDomain(forName: "UnlockWaiterTests.timeout")
        defaults.set(true, forKey: DefaultsKey.lockoutEnabled)
        delegate.testDefaults = defaults
        delegate.lastAuthenticatedAt = nil

        let result = await delegate.showPanelAndWaitForUnlock(timeoutSeconds: 0.25)
        #expect(result == false)
    }
}
