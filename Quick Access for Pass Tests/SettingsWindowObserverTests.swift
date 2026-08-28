import AppKit
import Testing
@testable import Quick_Access_for_Pass

@Suite("Settings window observer")
@MainActor
struct SettingsWindowObserverTests {
    @Test("Attaching the observer reports the Settings window")
    func attachingObserverReportsSettingsWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        var observedWindow: NSWindow?
        let observerView = SettingsWindowObserverView(
            onWindowAvailable: { observedWindow = $0 }
        )

        window.contentView = observerView

        #expect(observedWindow === window)
    }

    @Test("Attaching the observer preserves the system-managed window title")
    func attachingObserverPreservesWindowTitle() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "General"
        let observerView = SettingsWindowObserverView(onWindowAvailable: { _ in })

        window.contentView = observerView

        #expect(window.title == "General")
    }
}
