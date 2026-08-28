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

    @Test func hideRespectsBlockPredicateByDefault() {
        let controller = PanelController()
        var hideCount = 0
        controller.shouldBlockHide = { true }
        controller.onHide = { hideCount += 1 }

        controller.hide()

        #expect(hideCount == 0)
    }

    @Test func hideIgnoringBlockBypassesBlockPredicate() {
        let controller = PanelController()
        var hideCount = 0
        controller.shouldBlockHide = { true }
        controller.onHide = { hideCount += 1 }

        controller.hide(ignoringBlock: true)

        #expect(hideCount == 1)
    }

    @Test("Ordinary hide restores the previous application")
    func ordinaryHideRestoresPreviousApplication() {
        let previousApplication = NSRunningApplication.current
        var activatedProcessIdentifiers: [pid_t] = []
        let controller = PanelController(
            frontmostApplication: { previousApplication },
            activateApplication: { activatedProcessIdentifiers.append($0.processIdentifier) }
        )
        controller.show()

        controller.hide()

        #expect(activatedProcessIdentifiers == [previousApplication.processIdentifier])
    }

    @Test(
        "Window transition defers previous-application restoration",
        .bug("https://github.com/CiTroNaK/Quick-Access-for-Pass/issues/18")
    )
    func windowTransitionDefersPreviousApplicationRestoration() {
        let previousApplication = NSRunningApplication.current
        var activatedProcessIdentifiers: [pid_t] = []
        let controller = PanelController(
            frontmostApplication: { previousApplication },
            activateApplication: { activatedProcessIdentifiers.append($0.processIdentifier) }
        )
        controller.show()

        let deferredApplication = controller.hideForWindowTransition()

        #expect(deferredApplication?.processIdentifier == previousApplication.processIdentifier)
        #expect(activatedProcessIdentifiers.isEmpty)
    }
}
