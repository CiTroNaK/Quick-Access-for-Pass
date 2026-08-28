import AppKit

@MainActor
extension AppDelegate {
    /// Hides the quick-access panel while retaining its previous application for Settings dismissal.
    func prepareToOpenSettings() {
        let applicationToRestore = panelController?.hideForWindowTransition()
        settingsWindowCoordinator.deferFocusRestoration(to: applicationToRestore)
        NSApp.activate()
    }

    /// Handles key-window transitions, preserving focus when Settings replaces the quick panel.
    func handleWindowDidBecomeKey(_ window: NSWindow) {
        guard let panelController,
              panelController.isVisible,
              !panelController.isOwnWindow(window) else { return }

        if settingsWindowCoordinator.isSettingsWindow(window) {
            let applicationToRestore = panelController.hideForWindowTransition()
            settingsWindowCoordinator.deferFocusRestoration(to: applicationToRestore)
        } else {
            guard !panelController.isShowingTransition else { return }
            panelController.hide()
        }
    }
}
