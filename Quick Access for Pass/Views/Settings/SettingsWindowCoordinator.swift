import AppKit

/// Defers focus restoration while the Settings window is visible.
@MainActor
final class SettingsWindowCoordinator: NSObject {
    private let isCurrentApplicationActive: () -> Bool
    private let activateApplication: (NSRunningApplication) -> Void
    private var applicationToRestore: NSRunningApplication?
    private weak var observedSettingsWindow: NSWindow?

    init(
        isCurrentApplicationActive: @escaping () -> Bool = {
            NSRunningApplication.current.isActive
        },
        activateApplication: @escaping (NSRunningApplication) -> Void = { application in
            application.activate()
        }
    ) {
        self.isCurrentApplicationActive = isCurrentApplicationActive
        self.activateApplication = activateApplication
        super.init()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Observes the Settings window so deferred focus is restored when it closes.
    func observeSettingsWindow(_ window: NSWindow) {
        guard observedSettingsWindow !== window else { return }
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: nil
        )
        observedSettingsWindow = window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsWindowDidClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    /// Returns whether a window is the observed SwiftUI Settings window.
    func isSettingsWindow(_ window: NSWindow) -> Bool {
        window === observedSettingsWindow
    }

    /// Stores the application that should regain focus when Settings closes.
    func deferFocusRestoration(to application: NSRunningApplication?) {
        applicationToRestore = application
    }

    /// Restores deferred focus after the Settings window closes.
    func settingsWindowWillClose() {
        guard let applicationToRestore else { return }
        self.applicationToRestore = nil
        guard isCurrentApplicationActive() else { return }
        activateApplication(applicationToRestore)
    }

    @objc private func settingsWindowDidClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === observedSettingsWindow else { return }
        settingsWindowWillClose()
    }
}
