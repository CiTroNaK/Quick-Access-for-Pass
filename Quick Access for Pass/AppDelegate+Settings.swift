import AppKit

@MainActor
extension AppDelegate {
    /// Presents Settings through its current SwiftUI scene action after preparing focus.
    func presentSettings(using openSettings: () -> Void, restoring application: NSRunningApplication? = nil) {
        prepareToOpenSettings(restoring: application)
        openSettings()
    }

    /// Hides the quick-access panel while retaining its previous application for Settings dismissal.
    func prepareToOpenSettings(restoring application: NSRunningApplication? = nil) {
        let applicationToRestore = panelController?.hideForWindowTransition() ?? application
        settingsWindowCoordinator.deferFocusRestoration(to: applicationToRestore)
        activateSettingsApplication()
    }

    /// Handles a notification delivered by the main-queue observer synchronously.
    /// Deferring this work can let a Touch ID window's stale event hide the panel
    /// after the matching authentication attempt has already ended.
    nonisolated func handleWindowDidBecomeKeyNotification(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        MainActor.assumeIsolated { [weak self] in
            self?.handleWindowDidBecomeKey(window)
        }
    }

    /// Handles key-window transitions, preserving focus when Settings replaces the quick panel.
    func handleWindowDidBecomeKey(_ window: NSWindow) {
        guard let panelController, panelController.isVisible else { return }
        guard !panelController.isOwnWindow(window) else { return }

        if settingsWindowCoordinator.isSettingsWindow(window) {
            let applicationToRestore = panelController.hideForWindowTransition()
            settingsWindowCoordinator.deferFocusRestoration(to: applicationToRestore)
        } else {
            // Key-window notifications can arrive after the originating system
            // window has already relinquished focus. Ignore those stale events.
            guard keyWindowProvider() === window,
                  !panelController.isShowingTransition else { return }
            panelController.hide()
        }
    }
}
