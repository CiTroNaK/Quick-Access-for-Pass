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
    func lockedOnLaunchWhenEnabledNoAuth() {
        let defaults = makeDefaults(#function)
        defaults.set(true, forKey: DefaultsKey.lockoutEnabled)
        defaults.set(LockoutTimeout.oneHour.seconds, forKey: DefaultsKey.lockoutTimeout)
        let delegate = AppDelegate()
        delegate.testDefaults = defaults
        #expect(delegate.isLocked)
    }

    @Test
    func unlockedAfterRecentAuth() {
        let defaults = makeDefaults(#function)
        defaults.set(true, forKey: DefaultsKey.lockoutEnabled)
        defaults.set(LockoutTimeout.oneHour.seconds, forKey: DefaultsKey.lockoutTimeout)
        let delegate = AppDelegate()
        delegate.testDefaults = defaults
        delegate.resetAuthTimestamp()
        #expect(!delegate.isLocked)
    }

    @Test
    func lockedAfterTimeoutExpired() {
        let defaults = makeDefaults(#function)
        defaults.set(true, forKey: DefaultsKey.lockoutEnabled)
        defaults.set(LockoutTimeout.fifteenMinutes.seconds, forKey: DefaultsKey.lockoutTimeout)
        let delegate = AppDelegate()
        delegate.testDefaults = defaults
        delegate.lastAuthenticatedAt = Date().addingTimeInterval(-1000)
        #expect(delegate.isLocked)
    }

    @Test
    func notLockedJustBeforeTimeout() {
        let defaults = makeDefaults(#function)
        defaults.set(true, forKey: DefaultsKey.lockoutEnabled)
        defaults.set(LockoutTimeout.fifteenMinutes.seconds, forKey: DefaultsKey.lockoutTimeout)
        let delegate = AppDelegate()
        delegate.testDefaults = defaults
        delegate.lastAuthenticatedAt = Date().addingTimeInterval(-899)
        #expect(!delegate.isLocked)
    }

    @Test
    func resetAuthTimestampUpdatesDate() {
        let delegate = AppDelegate()
        #expect(delegate.lastAuthenticatedAt == nil)
        delegate.resetAuthTimestamp()
        #expect(delegate.lastAuthenticatedAt != nil)
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
