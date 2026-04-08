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

    /// Yield repeatedly to let pending MainActor tasks execute, then check a condition.
    @MainActor
    private static func waitFor(
        timeout: Duration = .milliseconds(2000),
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline {
                break
            }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(10))
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
    @MainActor func onCopyCallbackLabel() async throws {
        let pb = Self.makePasteboard("test-label")
        let manager = ClipboardManager(autoClearSeconds: 0, pasteboard: pb)
        var receivedLabel: String?
        manager.onCopy = { receivedLabel = $0 }

        manager.copy("abc", label: "Password copied")

        try await Self.waitFor { receivedLabel != nil }
        #expect(receivedLabel == "Password copied")
    }

    @Test("onCopy uses default label when none specified")
    @MainActor func onCopyDefaultLabel() async throws {
        let pb = Self.makePasteboard("test-default-label")
        let manager = ClipboardManager(autoClearSeconds: 0, pasteboard: pb)
        var receivedLabel: String?
        manager.onCopy = { receivedLabel = $0 }

        manager.copy("abc") // no label arg

        try await Self.waitFor { receivedLabel != nil }
        #expect(receivedLabel == "Copied to clipboard")
    }

    // MARK: - Auto-clear disabled

    @Test("autoClearSeconds = 0 disables auto-clear")
    @MainActor func zeroClearSecondsDisablesAutoClear() async throws {
        let pb = Self.makePasteboard("test-no-clear")
        let manager = ClipboardManager(autoClearSeconds: 0, pasteboard: pb)
        manager.copy("stay")
        // Even after a brief wait the content should remain because clear is disabled
        try await Task.sleep(for: .milliseconds(100))
        let value = pb.string(forType: .string)
        #expect(value == "stay")
    }

    // MARK: - Auto-clear respects external changes

    @Test("auto-clear does NOT clear if pasteboard was changed externally")
    @MainActor func autoClearSkipsIfExternallyChanged() async throws {
        let pb = Self.makePasteboard("test-external")
        let manager = ClipboardManager(autoClearSeconds: 0.1, pasteboard: pb)
        manager.copy("app-secret")

        // Simulate external paste after our copy
        pb.clearContents()
        pb.setString("user-pasted", forType: .string)

        try await Task.sleep(for: .milliseconds(300))
        // changeCount differs, so auto-clear should have been skipped
        #expect(pb.string(forType: .string) == "user-pasted")
    }

    @Test("auto-clear wipes content after timeout if unchanged")
    @MainActor func autoClearWipesAfterTimeout() async throws {
        let pb = Self.makePasteboard("test-auto-clear")
        let manager = ClipboardManager(autoClearSeconds: 0.1, pasteboard: pb)
        manager.copy("temp-secret")

        try await Self.waitFor { pb.string(forType: .string) != "temp-secret" }
        let value = pb.string(forType: .string)
        // Should be cleared (empty string)
        #expect(value == "" || value == nil)
    }

    // MARK: - Cancel on subsequent copy

    @Test("second copy cancels first auto-clear timer")
    @MainActor func secondCopyCancelsFirstTimer() async throws {
        let pb = Self.makePasteboard("test-cancel-timer")
        let manager = ClipboardManager(autoClearSeconds: 0.5, pasteboard: pb)
        manager.copy("first-secret")
        // Immediately copy again — should reset the timer
        manager.copy("second-secret")

        // After 200ms (well within the 500ms timeout), the content should still be present
        try await Task.sleep(for: .milliseconds(200))
        let value = pb.string(forType: .string)
        #expect(value == "second-secret")
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
}
