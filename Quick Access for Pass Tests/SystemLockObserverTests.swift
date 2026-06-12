import AppKit
import Testing
@testable import Quick_Access_for_Pass

@Suite("SystemLockObserver")
@MainActor
struct SystemLockObserverTests {
    @Test func simulationInvokesCallbackForBothEvents() {
        var eventCount = 0
        let observer = SystemLockObserver(notificationCenter: NotificationCenter()) {
            eventCount += 1
        }

        observer.simulateSessionDidResignActiveForTesting()
        observer.simulateWillSleepForTesting()

        #expect(eventCount == 2)
    }

    @Test func postedWorkspaceNotificationsInvokeCallback() async {
        let center = NotificationCenter()
        var eventCount = 0
        let observer = SystemLockObserver(notificationCenter: center) {
            eventCount += 1
        }

        observer.start()
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        await Task.yield()
        await Task.yield()
        observer.stop()

        #expect(eventCount == 2)
    }

    @Test func stopRemovesRegisteredObservers() async {
        let center = NotificationCenter()
        var eventCount = 0
        let observer = SystemLockObserver(notificationCenter: center) {
            eventCount += 1
        }

        observer.start()
        observer.stop()
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        await Task.yield()

        #expect(eventCount == 0)
    }

    @Test func repeatedStartDoesNotRegisterDuplicateObservers() async {
        let center = NotificationCenter()
        var eventCount = 0
        let observer = SystemLockObserver(notificationCenter: center) {
            eventCount += 1
        }

        observer.start()
        observer.start()
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        await Task.yield()
        observer.stop()

        #expect(eventCount == 1)
    }
}
