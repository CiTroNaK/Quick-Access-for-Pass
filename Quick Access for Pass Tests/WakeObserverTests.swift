import Testing
import Foundation
@testable import Quick_Access_for_Pass

@MainActor
struct WakeObserverTests {

    @Test func singleWakeFiresAfterDebounce() async {
        await confirmation("onWake invoked exactly once", expectedCount: 1) { confirm in
            let observer = WakeObserver(debounceSeconds: 0.05) {
                confirm()
            }
            let task = observer.simulateWakeForTesting()
            await task?.value
            observer.stop()
        }
    }

    @Test func burstOfWakesCoalescesToOneFire() async {
        await confirmation("burst collapses to 1 fire", expectedCount: 1) { confirm in
            let observer = WakeObserver(debounceSeconds: 0.1) {
                confirm()
            }
            _ = observer.simulateWakeForTesting()
            _ = observer.simulateWakeForTesting()
            let lastTask = observer.simulateWakeForTesting()
            await lastTask?.value
            observer.stop()
        }
    }

    @Test func stopCancelsPendingFire() async {
        await confirmation("onWake not invoked after stop", expectedCount: 0) { _ in
            let observer = WakeObserver(debounceSeconds: 0.1) {
                Issue.record("should not fire after stop")
            }
            _ = observer.simulateWakeForTesting()
            observer.stop()
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    @Test func subsequentWakeArmsAgainAfterFire() async {
        await confirmation("onWake invoked twice across two arms", expectedCount: 2) { confirm in
            let observer = WakeObserver(debounceSeconds: 0.05) {
                confirm()
            }
            let t1 = observer.simulateWakeForTesting()
            await t1?.value
            let t2 = observer.simulateWakeForTesting()
            await t2?.value
            observer.stop()
        }
    }
}
