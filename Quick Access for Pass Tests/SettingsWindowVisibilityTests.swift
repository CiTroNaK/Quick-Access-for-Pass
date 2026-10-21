import AppKit
import Testing
@testable import Quick_Access_for_Pass

@Suite("Settings window visibility")
@MainActor
struct SettingsWindowVisibilityTests {
    @Test func attachmentDefersPublicationAndReadsLatestVisibility() throws {
        let fixture = Fixture()
        let window = makeWindow()
        fixture.coordinator.observeSettingsWindow(window)
        #expect(!fixture.coordinator.isSettingsWindowVisible)
        #expect(fixture.queue.jobs.count == 1)
        fixture.visible = false
        fixture.queue.drain()
        #expect(!fixture.coordinator.isSettingsWindowVisible)
        fixture.visible = true
        post(NSWindow.didChangeOcclusionStateNotification, window)
        #expect(fixture.coordinator.isSettingsWindowVisible)
        #expect(!window.isKeyWindow)
    }

    @Test func closeInvalidatesQueuedPublicationAndRestoresFocusImmediately() {
        let fixture = Fixture()
        let window = makeWindow()
        fixture.coordinator.deferFocusRestoration(to: .current)
        fixture.coordinator.observeSettingsWindow(window)
        post(NSWindow.willCloseNotification, window)
        #expect(fixture.restored == 1)
        #expect(!fixture.coordinator.isSettingsWindowVisible)
        fixture.queue.drain()
        #expect(!fixture.coordinator.isSettingsWindowVisible)
        #expect(fixture.restored == 1)
        #expect(fixture.coordinator.isSettingsWindow(window))
    }

    @Test func replacementRejectsQueuedOldWindowAndOldNotifications() throws {
        let fixture = Fixture()
        let old = makeWindow()
        let current = makeWindow()
        fixture.coordinator.observeSettingsWindow(old)
        fixture.coordinator.observeSettingsWindow(current)
        try #require(fixture.queue.jobs.count == 2)
        fixture.queue.runFirst()
        #expect(!fixture.coordinator.isSettingsWindowVisible)
        fixture.queue.runFirst()
        #expect(fixture.coordinator.isSettingsWindowVisible)
        fixture.visible = false
        post(NSWindow.willCloseNotification, old)
        post(NSWindow.didChangeOcclusionStateNotification, old)
        post(NSWindow.didMiniaturizeNotification, old)
        #expect(fixture.coordinator.isSettingsWindowVisible)
        post(NSWindow.didChangeOcclusionStateNotification, current)
        #expect(!fixture.coordinator.isSettingsWindowVisible)
    }

    @Test func sameWindowReopenRejectsPreCloseRevision() throws {
        let fixture = Fixture()
        let window = makeWindow()
        fixture.coordinator.observeSettingsWindow(window)
        post(NSWindow.willCloseNotification, window)
        fixture.coordinator.observeSettingsWindow(window)
        try #require(fixture.queue.jobs.count == 2)
        fixture.queue.runFirst()
        #expect(!fixture.coordinator.isSettingsWindowVisible)
        fixture.queue.runFirst()
        #expect(fixture.coordinator.isSettingsWindowVisible)
        post(NSWindow.willCloseNotification, window)
        #expect(!fixture.coordinator.isSettingsWindowVisible)
    }

    @Test func attachmentAndBootstrapNotificationsCoalesceWithoutPublishingInline() {
        let fixture = Fixture()
        let window = makeWindow()
        fixture.coordinator.observeSettingsWindow(window)
        fixture.coordinator.observeSettingsWindow(window)
        post(NSWindow.didChangeOcclusionStateNotification, window)
        post(NSWindow.didBecomeKeyNotification, window)
        #expect(fixture.queue.jobs.count == 1)
        #expect(!fixture.coordinator.isSettingsWindowVisible)
        fixture.queue.drain()
        #expect(fixture.coordinator.isSettingsWindowVisible)
        #expect(fixture.queue.jobs.isEmpty)
    }

    @Test(arguments: [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                      NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification])
    func registeredNativeNotificationsRefreshCurrentVisibility(name: Notification.Name) {
        let fixture = Fixture()
        let window = makeWindow()
        fixture.coordinator.observeSettingsWindow(window)
        fixture.queue.drain()
        #expect(fixture.coordinator.isSettingsWindowVisible)
        fixture.visible = false
        NotificationCenter.default.post(name: name, object: window)
        #expect(!fixture.coordinator.isSettingsWindowVisible)
        fixture.visible = true
        NotificationCenter.default.post(name: name, object: window)
        #expect(fixture.coordinator.isSettingsWindowVisible)
    }

    @Test func reusedWindowReappearsWithoutAnotherAttachment() {
        let fixture = Fixture()
        let window = makeWindow()
        fixture.coordinator.observeSettingsWindow(window)
        fixture.queue.drain()
        post(NSWindow.willCloseNotification, window)
        post(NSWindow.didChangeOcclusionStateNotification, window)
        #expect(!fixture.coordinator.isSettingsWindowVisible)
        fixture.queue.drain()
        #expect(fixture.coordinator.isSettingsWindowVisible)
    }

    @Test func anUpdateDuringClosureCannotConsumeTheReappearanceWatch() {
        let fixture = Fixture()
        let window = makeWindow()
        fixture.coordinator.observeSettingsWindow(window)
        fixture.queue.drain()
        post(NSWindow.willCloseNotification, window)
        // willClose precedes the native isVisible transition. An update can queue in that interval.
        post(NSWindow.didUpdateNotification, window)
        fixture.visible = false
        fixture.queue.drain()
        #expect(!fixture.coordinator.isSettingsWindowVisible)
        fixture.visible = true
        post(NSWindow.didUpdateNotification, window)
        #expect(fixture.queue.jobs.count == 1)
        fixture.queue.drain()
        #expect(fixture.coordinator.isSettingsWindowVisible)
    }

    @Test func reusedNonKeyWindowUsesOneShotUpdateThenStopsWatchingFrames() {
        let fixture = Fixture()
        let window = makeWindow()
        fixture.coordinator.observeSettingsWindow(window)
        fixture.queue.drain()
        post(NSWindow.willCloseNotification, window)
        fixture.visible = false
        post(NSWindow.didUpdateNotification, window)
        #expect(fixture.queue.jobs.isEmpty)
        fixture.visible = true
        post(NSWindow.didUpdateNotification, makeWindow())
        #expect(fixture.queue.jobs.isEmpty)
        post(NSWindow.didUpdateNotification, window)
        #expect(!fixture.coordinator.isSettingsWindowVisible)
        #expect(fixture.queue.jobs.count == 1)
        fixture.queue.drain()
        #expect(fixture.coordinator.isSettingsWindowVisible)
        fixture.visible = false
        post(NSWindow.didUpdateNotification, window)
        #expect(fixture.coordinator.isSettingsWindowVisible)
        #expect(fixture.queue.jobs.isEmpty)
        post(NSWindow.didChangeOcclusionStateNotification, window)
        #expect(!fixture.coordinator.isSettingsWindowVisible)
    }

    @Test func queuedBootstrapDoesNotRetainCoordinator() {
        let queue = PendingRefreshes()
        var coordinator: SettingsWindowCoordinator? = SettingsWindowCoordinator(
            isWindowVisible: { _ in true }, enqueueVisibilityRefresh: { queue.jobs.append($0) }
        )
        weak let observed = coordinator
        let window = makeWindow()
        coordinator?.observeSettingsWindow(window)
        coordinator = nil
        #expect(observed == nil)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        queue.drain()
    }

    @Test func defaultVisibilityRejectsAnUnshownWindow() {
        let queue = PendingRefreshes()
        let coordinator = SettingsWindowCoordinator(enqueueVisibilityRefresh: { queue.jobs.append($0) })
        let window = makeWindow()
        coordinator.observeSettingsWindow(window)
        queue.drain()
        #expect(!coordinator.isSettingsWindowVisible)
    }

    private func post(_ name: Notification.Name, _ window: NSWindow) {
        NotificationCenter.default.post(name: name, object: window)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @MainActor
    private final class PendingRefreshes {
        var jobs: [@MainActor @Sendable () -> Void] = []
        func runFirst() { jobs.removeFirst()() }
        func drain() { while !jobs.isEmpty { runFirst() } }
    }

    @MainActor
    private final class Fixture {
        let queue = PendingRefreshes()
        var visible = true
        var restored = 0
        lazy var coordinator = SettingsWindowCoordinator(
            isCurrentApplicationActive: { true },
            activateApplication: { [weak self] _ in self?.restored += 1 },
            isWindowVisible: { [weak self] _ in self?.visible ?? false },
            enqueueVisibilityRefresh: { [weak self] in self?.queue.jobs.append($0) }
        )
    }
}
