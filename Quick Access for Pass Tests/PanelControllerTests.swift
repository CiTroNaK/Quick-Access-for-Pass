import Testing
import AppKit
@testable import Quick_Access_for_Pass

@Suite("PanelController")
@MainActor
struct PanelControllerTests {
    @Test func ownedAuxiliaryWindowCountsAsOwnWindow() {
        let controller = PanelController()
        let auxiliary = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        #expect(controller.isOwnWindow(auxiliary) == false)
        controller.registerOwnedWindow(auxiliary)
        #expect(controller.isOwnWindow(auxiliary))
        controller.unregisterOwnedWindow(auxiliary)
        #expect(controller.isOwnWindow(auxiliary) == false)
    }

    @Test func hideInvokesOnHideAuxiliaryExactlyOnce() {
        let controller = PanelController()
        var auxiliaryCloseCount = 0
        controller.onHideAuxiliary = { auxiliaryCloseCount += 1 }

        controller.hide()

        #expect(auxiliaryCloseCount == 1)
    }
}
