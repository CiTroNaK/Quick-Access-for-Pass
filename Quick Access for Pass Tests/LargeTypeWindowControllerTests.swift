import Testing
import AppKit
@testable import Quick_Access_for_Pass

@Suite("LargeTypeWindowController")
@MainActor
struct LargeTypeWindowControllerTests {
    @Test func showCreatesFloatingKeyWindowAndReusesIt() throws {
        let controller = LargeTypeWindowController(presentationMode: .headless)
        let display = try LargeTypeDisplay(validating: "A1@")

        controller.show(display: display, relativeTo: nil)
        let firstWindow = try #require(controller.debugWindow)
        controller.show(display: display, relativeTo: nil)
        let secondWindow = try #require(controller.debugWindow)

        #expect(firstWindow === secondWindow)
        #expect(firstWindow.level == .floating)
        #expect(firstWindow.canBecomeKey)
        #expect(firstWindow.isVisible == false)
    }

    @Test func showSizesWindowToFitAllCharacters() throws {
        let controller = LargeTypeWindowController(presentationMode: .headless)
        let display = try LargeTypeDisplay(validating: "abcdefghijkl")

        controller.show(display: display, relativeTo: nil)
        let window = try #require(controller.debugWindow)
        let visibleFrame = window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let expectedLayout = LargeTypeView.Layout.bestFit(tileCount: display.tiles.count, visibleFrame: visibleFrame)

        #expect(window.frame.size == expectedLayout.contentSize(for: display.tiles.count))
        #expect(window.frame.size != NSSize(width: 720, height: 320))
    }

    @Test func closeOrdersWindowOut() throws {
        let controller = LargeTypeWindowController(presentationMode: .headless)
        let display = try LargeTypeDisplay(validating: "AB12")

        controller.show(display: display, relativeTo: nil)
        controller.close()

        #expect(controller.debugWindow == nil)
    }

    @Test func showAndCloseNotifyOwnershipCallbacks() throws {
        let controller = LargeTypeWindowController(presentationMode: .headless)
        let display = try LargeTypeDisplay(validating: "AB12")
        var shownWindow: NSWindow?
        var closedWindow: NSWindow?
        controller.onWindowShown = { shownWindow = $0 }
        controller.onWindowClosed = { closedWindow = $0 }

        controller.show(display: display, relativeTo: nil)
        controller.close()

        #expect(shownWindow != nil)
        #expect(closedWindow === shownWindow)
    }
}
