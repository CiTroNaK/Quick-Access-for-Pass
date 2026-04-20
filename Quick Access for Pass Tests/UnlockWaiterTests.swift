import Testing
import Foundation
@testable import Quick_Access_for_Pass

@Suite("AppDelegate unlock waiters")
@MainActor
struct UnlockWaiterTests {

    @Test func resetAuthTimestampResumesWaiterAndRefreshesActivity() async throws {
        let delegate = AppDelegate()
        let defaults = UserDefaults(suiteName: "UnlockWaiterTests.resumesWaiterAndRefreshesActivity")!
        defaults.removePersistentDomain(forName: "UnlockWaiterTests.resumesWaiterAndRefreshesActivity")
        defaults.set(true, forKey: DefaultsKey.lockoutEnabled)
        delegate.testDefaults = defaults
        delegate.lastAuthenticatedAt = Date(timeIntervalSince1970: 100)
        delegate.lastActivityAt = Date(timeIntervalSince1970: 200)

        async let waited = delegate.showPanelAndWaitForUnlock()

        // Deterministic: spin until the child Task has registered its
        // continuation. Avoids reliance on wall-clock sleeps.
        while delegate.pendingUnlockWaiters.isEmpty {
            await Task.yield()
        }

        delegate.resetAuthTimestamp()

        #expect(await waited == true)
        let refreshedAuth = try #require(delegate.lastAuthenticatedAt)
        let refreshedActivity = try #require(delegate.lastActivityAt)
        #expect(refreshedAuth > Date(timeIntervalSince1970: 100))
        #expect(refreshedActivity > Date(timeIntervalSince1970: 200))
        #expect(abs(refreshedAuth.timeIntervalSince(refreshedActivity)) < 0.1)
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
