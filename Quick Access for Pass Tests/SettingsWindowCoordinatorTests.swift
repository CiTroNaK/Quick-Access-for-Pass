import AppKit
import Testing
@testable import Quick_Access_for_Pass

@Suite("Settings window focus")
@MainActor
struct SettingsWindowCoordinatorTests {
    @Test(
        "Closing Settings restores the deferred application once",
        .bug("https://github.com/CiTroNaK/Quick-Access-for-Pass/issues/18")
    )
    func closingSettingsRestoresDeferredApplicationOnce() {
        let previousApplication = NSRunningApplication.current
        var activatedProcessIdentifiers: [pid_t] = []
        let coordinator = SettingsWindowCoordinator(
            isCurrentApplicationActive: { true },
            activateApplication: { activatedProcessIdentifiers.append($0.processIdentifier) }
        )
        let firstWindow = makeWindow()
        coordinator.deferFocusRestoration(to: previousApplication)
        coordinator.observeSettingsWindow(firstWindow)

        firstWindow.close()
        let secondWindow = makeWindow()
        coordinator.observeSettingsWindow(secondWindow)
        secondWindow.close()

        #expect(activatedProcessIdentifiers == [previousApplication.processIdentifier])
    }

    @Test("Closing Settings does not steal focus when Quick Access is inactive")
    func closingSettingsDoesNotStealFocusWhenInactive() {
        let previousApplication = NSRunningApplication.current
        var isCurrentApplicationActive = false
        var activatedProcessIdentifiers: [pid_t] = []
        let coordinator = SettingsWindowCoordinator(
            isCurrentApplicationActive: { isCurrentApplicationActive },
            activateApplication: { activatedProcessIdentifiers.append($0.processIdentifier) }
        )
        let firstWindow = makeWindow()
        coordinator.deferFocusRestoration(to: previousApplication)
        coordinator.observeSettingsWindow(firstWindow)

        firstWindow.close()
        isCurrentApplicationActive = true
        let secondWindow = makeWindow()
        coordinator.observeSettingsWindow(secondWindow)
        secondWindow.close()

        #expect(activatedProcessIdentifiers.isEmpty)
    }

    @Test(
        "Preparing Settings hides the panel without immediately restoring focus",
        .bug("https://github.com/CiTroNaK/Quick-Access-for-Pass/issues/18")
    )
    func preparingSettingsDefersPanelFocusRestoration() {
        let previousApplication = NSRunningApplication.current
        var immediateActivations: [pid_t] = []
        var deferredActivations: [pid_t] = []
        let panelController = PanelController(
            frontmostApplication: { previousApplication },
            activateApplication: { immediateActivations.append($0.processIdentifier) }
        )
        let settingsWindowCoordinator = SettingsWindowCoordinator(
            isCurrentApplicationActive: { true },
            activateApplication: { deferredActivations.append($0.processIdentifier) }
        )
        let appDelegate = AppDelegate()
        appDelegate.panelController = panelController
        appDelegate.settingsWindowCoordinator = settingsWindowCoordinator
        panelController.show()

        appDelegate.prepareToOpenSettings()

        #expect(panelController.isVisible == false)
        #expect(immediateActivations.isEmpty)
        settingsWindowCoordinator.settingsWindowWillClose()
        #expect(deferredActivations == [previousApplication.processIdentifier])
    }

    @Test(
        "Settings becoming key transitions a visible panel without immediately restoring focus",
        .bug("https://github.com/CiTroNaK/Quick-Access-for-Pass/issues/18")
    )
    func settingsBecomingKeyTransitionsVisiblePanel() {
        let previousApplication = NSRunningApplication.current
        var immediateActivations: [pid_t] = []
        var deferredActivations: [pid_t] = []
        let panelController = PanelController(
            frontmostApplication: { previousApplication },
            activateApplication: { immediateActivations.append($0.processIdentifier) }
        )
        let coordinator = SettingsWindowCoordinator(
            isCurrentApplicationActive: { true },
            activateApplication: { deferredActivations.append($0.processIdentifier) }
        )
        let settingsWindow = makeWindow()
        let appDelegate = AppDelegate()
        appDelegate.panelController = panelController
        appDelegate.settingsWindowCoordinator = coordinator
        coordinator.observeSettingsWindow(settingsWindow)
        panelController.show()

        appDelegate.handleWindowDidBecomeKey(settingsWindow)

        #expect(panelController.isVisible == false)
        #expect(immediateActivations.isEmpty)
        settingsWindow.close()
        #expect(deferredActivations == [previousApplication.processIdentifier])
    }

    @Test("A closed Settings window remains recognized when SwiftUI reuses it")
    func closedSettingsWindowRemainsRecognized() {
        let coordinator = SettingsWindowCoordinator()
        let settingsWindow = makeWindow()
        coordinator.observeSettingsWindow(settingsWindow)

        settingsWindow.close()

        #expect(coordinator.isSettingsWindow(settingsWindow))
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }
}
