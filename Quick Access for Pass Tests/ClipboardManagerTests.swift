import Testing
import Foundation
import AppKit
@testable import Quick_Access_for_Pass

@Suite("ClipboardManager Tests")
struct ClipboardManagerTests {

    /// Each test gets its own named pasteboard to avoid interference from parallel tests.
    private static func makePasteboard(_ name: String) -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name(name))
    }

    @MainActor
    private final class TestClipboardScheduler: ClipboardScheduling {
        @MainActor
        private final class ScheduledWork: ClipboardScheduledWork {
            private let operation: @MainActor () -> Void
            private(set) var isCancelled = false

            init(operation: @escaping @MainActor () -> Void) {
                self.operation = operation
            }

            func cancel() {
                isCancelled = true
            }

            func run() {
                guard !isCancelled else { return }
                operation()
            }
        }

        private var scheduledWork: [ScheduledWork] = []

        var scheduledCount: Int {
            scheduledWork.count
        }

        @discardableResult
        func schedule(
            after delay: Duration,
            operation: @escaping @MainActor () -> Void
        ) -> ClipboardScheduledWork {
            let work = ScheduledWork(operation: operation)
            scheduledWork.append(work)
            return work
        }

        func runScheduledWork(at index: Int = 0) {
            let work = scheduledWork.remove(at: index)
            work.run()
        }
    }

    // MARK: - Copy behaviour

    @Test("copy puts text on pasteboard")
    @MainActor func copyPutsTextOnPasteboard() {
        let pb = Self.makePasteboard("test-copy")
        let manager = ClipboardManager(autoClearSeconds: 0, pasteboard: pb)
        manager.copy("secret123")
        let value = pb.string(forType: .string)
        #expect(value == "secret123")
    }

    @Test("copy overwrites previous pasteboard content")
    @MainActor func copyOverwritesPrevious() {
        let pb = Self.makePasteboard("test-overwrite")
        let manager = ClipboardManager(autoClearSeconds: 0, pasteboard: pb)
        manager.copy("first")
        manager.copy("second")
        let value = pb.string(forType: .string)
        #expect(value == "second")
    }

    @Test("onCopy callback fires with correct label")
    @MainActor func onCopyCallbackLabel() {
        let pb = Self.makePasteboard("test-label")
        let scheduler = TestClipboardScheduler()
        let manager = ClipboardManager(autoClearSeconds: 0, pasteboard: pb, scheduler: scheduler)
        var receivedLabel: String?
        manager.onCopy = { receivedLabel = $0 }

        manager.copy("abc", label: "Password copied")

        #expect(receivedLabel == nil)
        #expect(scheduler.scheduledCount == 1)
        scheduler.runScheduledWork()
        #expect(receivedLabel == "Password copied")
    }

    @Test("onCopy uses default label when none specified")
    @MainActor func onCopyDefaultLabel() {
        let pb = Self.makePasteboard("test-default-label")
        let scheduler = TestClipboardScheduler()
        let manager = ClipboardManager(autoClearSeconds: 0, pasteboard: pb, scheduler: scheduler)
        var receivedLabel: String?
        manager.onCopy = { receivedLabel = $0 }

        manager.copy("abc") // no label arg

        #expect(receivedLabel == nil)
        #expect(scheduler.scheduledCount == 1)
        scheduler.runScheduledWork()
        #expect(receivedLabel == "Copied to clipboard")
    }

    // MARK: - Auto-clear disabled

    @Test("autoClearSeconds = 0 disables auto-clear")
    @MainActor func zeroClearSecondsDisablesAutoClear() {
        let pb = Self.makePasteboard("test-no-clear")
        let scheduler = TestClipboardScheduler()
        let manager = ClipboardManager(autoClearSeconds: 0, pasteboard: pb, scheduler: scheduler)
        manager.copy("stay")

        #expect(scheduler.scheduledCount == 1)
        scheduler.runScheduledWork()
        let value = pb.string(forType: .string)
        #expect(value == "stay")
    }

    // MARK: - Auto-clear respects external changes

    @Test("auto-clear does NOT clear if pasteboard was changed externally")
    @MainActor func autoClearSkipsIfExternallyChanged() {
        let pb = Self.makePasteboard("test-external")
        let scheduler = TestClipboardScheduler()
        let manager = ClipboardManager(autoClearSeconds: 0.1, pasteboard: pb, scheduler: scheduler)
        manager.copy("app-secret")

        // Simulate external paste after our copy
        pb.clearContents()
        pb.setString("user-pasted", forType: .string)

        #expect(scheduler.scheduledCount == 2)
        scheduler.runScheduledWork(at: 0)
        // changeCount differs, so auto-clear should have been skipped
        #expect(pb.string(forType: .string) == "user-pasted")
    }

    @Test("auto-clear wipes content after timeout if unchanged")
    @MainActor func autoClearWipesAfterTimeout() {
        let pb = Self.makePasteboard("test-auto-clear")
        let scheduler = TestClipboardScheduler()
        let manager = ClipboardManager(autoClearSeconds: 0.1, pasteboard: pb, scheduler: scheduler)
        manager.copy("temp-secret")

        #expect(pb.string(forType: .string) == "temp-secret")
        #expect(scheduler.scheduledCount == 2)
        scheduler.runScheduledWork(at: 0)

        let value = pb.string(forType: .string)
        #expect(value == "" || value == nil)
    }

    // MARK: - Cancel on subsequent copy

    @Test("second copy cancels first auto-clear timer")
    @MainActor func secondCopyCancelsFirstTimer() {
        let pb = Self.makePasteboard("test-cancel-timer")
        let scheduler = TestClipboardScheduler()
        let manager = ClipboardManager(autoClearSeconds: 0.5, pasteboard: pb, scheduler: scheduler)
        manager.copy("first-secret")
        // Immediately copy again — should reset the timer
        manager.copy("second-secret")

        #expect(scheduler.scheduledCount == 4)

        scheduler.runScheduledWork(at: 0)
        #expect(pb.string(forType: .string) == "second-secret")

        scheduler.runScheduledWork(at: 1)
        let value = pb.string(forType: .string)
        #expect(value == "" || value == nil)
    }

    // MARK: - Concealment

    @Test("copy sets ConcealedType when concealment is enabled")
    @MainActor func concealmentEnabled() {
        let pb = Self.makePasteboard("test-concealment-on")
        let defaults = UserDefaults(suiteName: "test-conceal-on-\(UUID().uuidString)")!
        defaults.set(true, forKey: DefaultsKey.concealFromClipboardManagers)

        let manager = ClipboardManager(autoClearSeconds: 0, pasteboard: pb, userDefaults: defaults)
        manager.copy("secret")

        let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        #expect(pb.data(forType: concealedType) != nil)
    }

    @Test("copy does not set ConcealedType when concealment is disabled")
    @MainActor func concealmentDisabled() {
        let pb = Self.makePasteboard("test-concealment-off")
        let defaults = UserDefaults(suiteName: "test-conceal-off-\(UUID().uuidString)")!
        defaults.set(false, forKey: DefaultsKey.concealFromClipboardManagers)

        let manager = ClipboardManager(autoClearSeconds: 0, pasteboard: pb, userDefaults: defaults)
        manager.copy("secret")

        let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        #expect(pb.data(forType: concealedType) == nil)
    }

    // MARK: - System-lock clearing

    @Test("clearIfOwned clears unchanged Quick Access clipboard content")
    @MainActor func clearIfOwnedClearsUnchangedContent() {
        let pb = Self.makePasteboard("test-clear-owned")
        let manager = ClipboardManager(autoClearSeconds: 0, pasteboard: pb)
        manager.copy("lock-secret")

        let didClear = manager.clearIfOwned()

        #expect(didClear)
        let value = pb.string(forType: .string)
        #expect(value == nil || value == "")
    }

    @Test("clearIfOwned preserves externally changed clipboard content")
    @MainActor func clearIfOwnedPreservesExternalChange() {
        let pb = Self.makePasteboard("test-clear-owned-external")
        let manager = ClipboardManager(autoClearSeconds: 0, pasteboard: pb)
        manager.copy("lock-secret")

        pb.clearContents()
        pb.setString("user-value", forType: .string)

        let didClear = manager.clearIfOwned()

        #expect(didClear == false)
        #expect(pb.string(forType: .string) == "user-value")
    }
}
