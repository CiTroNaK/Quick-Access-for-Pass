import AppKit
import Observation

/// Owns Settings visibility admission and deferred focus restoration, without retaining its window.
@MainActor
@Observable
final class SettingsWindowCoordinator: NSObject {
    private(set) var isSettingsWindowVisible = false

    @ObservationIgnored private let isCurrentApplicationActive: () -> Bool
    @ObservationIgnored private let activateApplication: (NSRunningApplication) -> Void
    @ObservationIgnored private let isWindowVisible: (NSWindow) -> Bool
    @ObservationIgnored private let enqueueVisibilityRefresh: (@escaping @MainActor @Sendable () -> Void) -> Void
    @ObservationIgnored private var applicationToRestore: NSRunningApplication?
    @ObservationIgnored private weak var observedSettingsWindow: NSWindow?
    @ObservationIgnored private var registrationRevision = UUID()
    @ObservationIgnored private var pendingBootstrapRevision: UUID?
    @ObservationIgnored private var hasPublishedVisibility = false
    @ObservationIgnored private var awaitsReappearanceUpdate = false

    init(
        isCurrentApplicationActive: @escaping () -> Bool = {
            NSRunningApplication.current.isActive
        },
        activateApplication: @escaping (NSRunningApplication) -> Void = { application in
            application.activate()
        },
        isWindowVisible: @escaping (NSWindow) -> Bool = {
            $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        },
        enqueueVisibilityRefresh: @escaping (@escaping @MainActor @Sendable () -> Void) -> Void = { operation in
            // AppKit attachment can occur during SwiftUI updates: leave that call stack before publishing.
            DispatchQueue.main.async { operation() }
        }
    ) {
        self.isCurrentApplicationActive = isCurrentApplicationActive
        self.activateApplication = activateApplication
        self.isWindowVisible = isWindowVisible
        self.enqueueVisibilityRefresh = enqueueVisibilityRefresh
        super.init()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Registers synchronously; initial visibility publication never runs in the attachment stack.
    func observeSettingsWindow(_ window: NSWindow) {
        if observedSettingsWindow !== window {
            for name in [NSWindow.willCloseNotification, NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.didBecomeKeyNotification, NSWindow.didUpdateNotification] {
                NotificationCenter.default.removeObserver(self, name: name, object: nil)
            }
            awaitsReappearanceUpdate = false
            invalidatePendingVisibility()
            observedSettingsWindow = window
            NotificationCenter.default.addObserver(
                self, selector: #selector(settingsWindowDidClose(_:)),
                name: NSWindow.willCloseNotification, object: window
            )
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(settingsWindowVisibilityDidChange(_:)), name: name, object: window
                )
            }
        }
        hasPublishedVisibility = false
        enqueueBootstrap(for: window)
    }

    /// Refreshes only the current window, respecting pending attachment/reopen publication.
    func refreshVisibility(of window: NSWindow) {
        guard window === observedSettingsWindow else { return }
        guard hasPublishedVisibility else {
            enqueueBootstrap(for: window)
            return
        }
        let visible = isWindowVisible(window)
        if visible { stopWatchingReappearance(of: window) }
        if isSettingsWindowVisible != visible { isSettingsWindowVisible = visible }
    }

    /// Returns whether a window is the observed SwiftUI Settings window, including after closure.
    func isSettingsWindow(_ window: NSWindow) -> Bool {
        window === observedSettingsWindow
    }

    /// Records a new restoration target without discarding one on repeat presentation.
    func deferFocusRestoration(to application: NSRunningApplication?) {
        guard let application else { return }
        applicationToRestore = application
    }

    /// Invalidates animation admission immediately and restores deferred focus at most once.
    func settingsWindowWillClose() {
        invalidatePendingVisibility()
        isSettingsWindowVisible = false
        if let window = observedSettingsWindow, !awaitsReappearanceUpdate {
            // A reused non-key window may reopen with no attachment/key/occlusion event.
            // Watch its updates only until reappearance, never its steady-state animation frames.
            awaitsReappearanceUpdate = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(settingsWindowDidUpdate(_:)), name: NSWindow.didUpdateNotification, object: window
            )
        }
        guard let applicationToRestore else { return }
        self.applicationToRestore = nil
        guard isCurrentApplicationActive() else { return }
        activateApplication(applicationToRestore)
    }

    private func invalidatePendingVisibility() {
        registrationRevision = UUID()
        pendingBootstrapRevision = nil
        hasPublishedVisibility = false
    }

    private func enqueueBootstrap(for window: NSWindow) {
        let revision = registrationRevision
        guard pendingBootstrapRevision != revision else { return }
        pendingBootstrapRevision = revision
        enqueueVisibilityRefresh { [weak self, weak window] in
            guard let self, let window,
                  self.registrationRevision == revision,
                  self.observedSettingsWindow === window else { return }
            self.pendingBootstrapRevision = nil
            self.hasPublishedVisibility = true
            self.refreshVisibility(of: window)
        }
    }

    private func stopWatchingReappearance(of window: NSWindow) {
        guard awaitsReappearanceUpdate else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didUpdateNotification, object: window)
        awaitsReappearanceUpdate = false
    }

    @objc private func settingsWindowDidUpdate(_ notification: Notification) {
        guard awaitsReappearanceUpdate,
              let window = notification.object as? NSWindow,
              window === observedSettingsWindow, isWindowVisible(window) else { return }
        // Keep the watch until deferred sampling confirms eligibility: willClose can precede isVisible=false.
        hasPublishedVisibility = false
        enqueueBootstrap(for: window)
    }

    @objc private func settingsWindowVisibilityDidChange(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        refreshVisibility(of: window)
    }

    @objc private func settingsWindowDidClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === observedSettingsWindow else { return }
        settingsWindowWillClose()
    }
}
