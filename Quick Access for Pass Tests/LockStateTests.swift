import Testing
import Foundation
@testable import Quick_Access_for_Pass

@Suite(.serialized)
@MainActor
struct LockStateTests {
    private func makeDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test
    func unlockedWhenDisabled() {
        let defaults = makeDefaults(#function)
        defaults.set(false, forKey: DefaultsKey.lockoutEnabled)
        let delegate = AppDelegate()
        delegate.testDefaults = defaults
        #expect(!delegate.isLocked)
    }

    @Test
    func lockedWhenNoActivityRecordedYet() {
        let defaults = makeDefaults(#function)
        defaults.set(true, forKey: DefaultsKey.lockoutEnabled)
        defaults.set(LockoutTimeout.oneHour.seconds, forKey: DefaultsKey.lockoutTimeout)
        let delegate = AppDelegate()
        delegate.testDefaults = defaults
        #expect(delegate.isLocked)
    }

    @Test
    func unlockedAfterRecentActivity() {
        let defaults = makeDefaults(#function)
        defaults.set(true, forKey: DefaultsKey.lockoutEnabled)
        defaults.set(LockoutTimeout.oneHour.seconds, forKey: DefaultsKey.lockoutTimeout)
        let delegate = AppDelegate()
        delegate.testDefaults = defaults
        delegate.recordActivity()
        #expect(!delegate.isLocked)
    }

    @Test
    func lockedAfterTimeoutExpired() {
        let defaults = makeDefaults(#function)
        defaults.set(true, forKey: DefaultsKey.lockoutEnabled)
        defaults.set(LockoutTimeout.fifteenMinutes.seconds, forKey: DefaultsKey.lockoutTimeout)
        let delegate = AppDelegate()
        delegate.testDefaults = defaults
        delegate.lastActivityAt = Date().addingTimeInterval(-1000)
        #expect(delegate.isLocked)
    }

    @Test
    func notLockedJustBeforeTimeout() {
        let defaults = makeDefaults(#function)
        defaults.set(true, forKey: DefaultsKey.lockoutEnabled)
        defaults.set(LockoutTimeout.fifteenMinutes.seconds, forKey: DefaultsKey.lockoutTimeout)
        let delegate = AppDelegate()
        delegate.testDefaults = defaults
        delegate.lastActivityAt = Date().addingTimeInterval(-890)
        #expect(!delegate.isLocked)
    }

    @Test
    func successfulAuthenticationRefreshesAuthAndActivityTimestamps() throws {
        let delegate = AppDelegate()
        let oldAuth = Date(timeIntervalSince1970: 100)
        let oldActivity = Date(timeIntervalSince1970: 200)

        delegate.lastAuthenticatedAt = oldAuth
        delegate.lastActivityAt = oldActivity

        delegate.resetAuthTimestamp()

        let refreshedAuth = try #require(delegate.lastAuthenticatedAt)
        let refreshedActivity = try #require(delegate.lastActivityAt)
        #expect(refreshedAuth > oldAuth)
        #expect(refreshedActivity > oldActivity)
        #expect(abs(refreshedAuth.timeIntervalSince(refreshedActivity)) < 0.1)
    }

    @Test
    func recordActivityRefreshesOnlyActivityTimestamp() throws {
        let delegate = AppDelegate()
        let existingAuth = Date(timeIntervalSince1970: 100)
        let oldActivity = Date(timeIntervalSince1970: 200)

        delegate.lastAuthenticatedAt = existingAuth
        delegate.lastActivityAt = oldActivity

        delegate.recordActivity()

        let refreshedActivity = try #require(delegate.lastActivityAt)
        #expect(delegate.lastAuthenticatedAt == existingAuth)
        #expect(refreshedActivity > oldActivity)
    }

    @Test
    func forceLockSetsLockedRegardlessOfTimestamp() {
        let defaults = makeDefaults(#function)
        defaults.set(true, forKey: DefaultsKey.lockoutEnabled)
        defaults.set(LockoutTimeout.oneHour.seconds, forKey: DefaultsKey.lockoutTimeout)
        let delegate = AppDelegate()
        delegate.testDefaults = defaults
        delegate.resetAuthTimestamp()
        #expect(!delegate.isLocked)
        delegate.forceLock()
        #expect(delegate.isLocked)
    }

    @Test
    func pendingLockContextDefaultsToNil() {
        let delegate = AppDelegate()
        #expect(delegate.pendingLockContext == nil)
    }
}
