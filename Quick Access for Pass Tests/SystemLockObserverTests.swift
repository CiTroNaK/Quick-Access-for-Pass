import AppKit
import Testing
@testable import Quick_Access_for_Pass

private struct TestDistributedNotificationRegistration {
    weak var observer: NSObject?
    let selector: Selector
    let name: Notification.Name?
}

@Suite("SystemLockObserver")
@MainActor
struct SystemLockObserverTests {
    private final class TestDistributedNotificationCenter: SystemLockDistributedNotificationCenter {
        private var registrations: [TestDistributedNotificationRegistration] = []
        private(set) var lastSuspensionBehavior: DistributedNotificationCenter.SuspensionBehavior?

        func addObserver(
            _ observer: Any,
            selector: Selector,
            name: Notification.Name?,
            object: String?,
            suspensionBehavior: DistributedNotificationCenter.SuspensionBehavior
        ) {
            guard let observer = observer as? NSObject else {
                Issue.record("Distributed notification observer must be an NSObject")
                return
            }
            registrations.append(TestDistributedNotificationRegistration(observer: observer, selector: selector, name: name))
            lastSuspensionBehavior = suspensionBehavior
        }

        func removeObserver(_ observer: Any) {
            guard let observer = observer as? NSObject else { return }
            registrations.removeAll { $0.observer === observer }
        }

        func post(name: Notification.Name) {
            for registration in registrations where registration.name == name {
                _ = registration.observer?.perform(registration.selector, with: Notification(name: name))
            }
        }
    }

    private func waitFor(
        timeout: Duration = .milliseconds(1000),
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline { break }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func simulationInvokesCallbackForAllLockEvents() {
        var eventCount = 0
        let observer = SystemLockObserver(
            workspaceNotificationCenter: NotificationCenter(),
            distributedNotificationCenter: TestDistributedNotificationCenter()
        ) {
            eventCount += 1
        }

        observer.simulateSessionDidResignActiveForTesting()
        observer.simulateWillSleepForTesting()
        observer.simulateScreenIsLockedForTesting()

        #expect(eventCount == 3)
    }

    @Test func postedWorkspaceNotificationsInvokeCallback() async throws {
        let workspaceCenter = NotificationCenter()
        let distributedCenter = TestDistributedNotificationCenter()
        var eventCount = 0
        let observer = SystemLockObserver(
            workspaceNotificationCenter: workspaceCenter,
            distributedNotificationCenter: distributedCenter
        ) {
            eventCount += 1
        }

        observer.start()
        workspaceCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await waitFor { eventCount == 2 }
        observer.stop()

        #expect(eventCount == 2)
    }

    @Test func postedScreenLockNotificationInvokesCallbackImmediately() async throws {
        let workspaceCenter = NotificationCenter()
        let distributedCenter = TestDistributedNotificationCenter()
        var eventCount = 0
        let observer = SystemLockObserver(
            workspaceNotificationCenter: workspaceCenter,
            distributedNotificationCenter: distributedCenter
        ) {
            eventCount += 1
        }

        observer.start()
        distributedCenter.post(name: SystemLockObserver.screenIsLockedNotification)
        try await waitFor { eventCount == 1 }
        observer.stop()

        #expect(eventCount == 1)
        #expect(distributedCenter.lastSuspensionBehavior == .deliverImmediately)
    }

    @Test func stopRemovesRegisteredObserversFromBothCenters() async throws {
        let workspaceCenter = NotificationCenter()
        let distributedCenter = TestDistributedNotificationCenter()
        var eventCount = 0
        let observer = SystemLockObserver(
            workspaceNotificationCenter: workspaceCenter,
            distributedNotificationCenter: distributedCenter
        ) {
            eventCount += 1
        }

        observer.start()
        observer.stop()
        workspaceCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        distributedCenter.post(name: SystemLockObserver.screenIsLockedNotification)
        try await waitFor(timeout: .milliseconds(100)) { eventCount > 0 }

        #expect(eventCount == 0)
    }

    @Test func repeatedStartDoesNotRegisterDuplicateObservers() async throws {
        let workspaceCenter = NotificationCenter()
        let distributedCenter = TestDistributedNotificationCenter()
        var eventCount = 0
        let observer = SystemLockObserver(
            workspaceNotificationCenter: workspaceCenter,
            distributedNotificationCenter: distributedCenter
        ) {
            eventCount += 1
        }

        observer.start()
        observer.start()
        workspaceCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        distributedCenter.post(name: SystemLockObserver.screenIsLockedNotification)
        try await waitFor { eventCount == 2 }
        observer.stop()

        #expect(eventCount == 2)
    }
}
