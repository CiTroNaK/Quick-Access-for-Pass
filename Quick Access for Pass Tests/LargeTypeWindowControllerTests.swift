import Testing
import AppKit
import os
@testable import Quick_Access_for_Pass

@Suite("LargeTypeWindowController")
@MainActor
struct LargeTypeWindowControllerTests {
    @Test(arguments: [false, true]) func guardedAttachmentDoesNotPostKeyOrResizeCallbacksAndCompletesOnce(reuse: Bool) throws {
        let controller = LargeTypeWindowController(presentationMode: .headless)
        if reuse { controller.show(display: try LargeTypeDisplay(validating: "OLD"), relativeTo: nil) }
        let prepared = controller.prepare(display: try LargeTypeDisplay(validating: "FIXTURE"), relativeTo: nil)
        let callbacks = OSAllocatedUnfairLock(initialState: [String]())
        let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didResizeNotification]
        let observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: prepared.window, queue: nil) { note in
                let name = note.name.rawValue
                callbacks.withLock { $0.append(name) }
            }
        }
        defer { observers.forEach(NotificationCenter.default.removeObserver); controller.close() }
        var shown = 0
        controller.onWindowShown = { _ in shown += 1 }
        try controller.activatePreparedWindow(prepared)
        try controller.present(prepared)
        #expect(callbacks.withLock { $0 }.isEmpty)
        #expect(prepared.window.contentViewController != nil)
        #expect(shown == 0)
        controller.completePresentation(prepared)
        controller.completePresentation(prepared)
        #expect(shown == 1)
    }

    @Test func preparationRegistersBlankShellAndDiscardIsIdempotent() throws {
        let controller = LargeTypeWindowController(presentationMode: .headless)
        var events: [String] = []
        controller.onWindowPrepared = { window in
            #expect(window.contentViewController == nil)
            #expect(controller.debugWindow == nil)
            events.append("prepared")
        }
        controller.onPreparationDiscarded = { _ in events.append("discarded") }
        controller.onWindowShown = { _ in events.append("shown") }
        let prepared = controller.prepare(display: try LargeTypeDisplay(validating: "NEW"), relativeTo: nil)
        try controller.activatePreparedWindow(prepared)
        #expect(prepared.window.contentViewController == nil)
        controller.discard(prepared)
        controller.discard(prepared)
        #expect(throws: (any Error).self) { try controller.present(prepared) }
        controller.completePresentation(prepared)
        #expect(events == ["prepared", "discarded"])
    }

    @Test func failedReuseRetainsPreviousReleasedContentAndRegistration() throws {
        let controller = LargeTypeWindowController(presentationMode: .headless)
        controller.show(display: try LargeTypeDisplay(validating: "OLD"), relativeTo: nil)
        let window = try #require(controller.debugWindow)
        let content = try #require(window.contentViewController)
        var discarded = 0
        controller.onPreparationDiscarded = { _ in discarded += 1 }
        let prepared = controller.prepare(display: try LargeTypeDisplay(validating: "NEW"), relativeTo: nil)
        try controller.activatePreparedWindow(prepared)
        #expect(window.contentViewController === content)
        controller.discard(prepared)
        #expect(window.contentViewController === content)
        #expect(controller.debugWindow === window)
        #expect(discarded == 0)
    }

    @Test func reentrantPreparationCloseCannotReopenDiscardedShell() throws {
        let controller = LargeTypeWindowController(presentationMode: .headless)
        controller.onWindowPrepared = { _ in controller.close() }
        let prepared = controller.prepare(display: try LargeTypeDisplay(validating: "NEW"), relativeTo: nil)
        #expect(throws: (any Error).self) { try controller.activatePreparedWindow(prepared) }
        #expect(throws: (any Error).self) { try controller.present(prepared) }
        #expect(prepared.hostingController == nil)
        #expect(controller.debugWindow == nil)
    }

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
        #expect(controller.debugHostingController != nil)
        controller.close()

        #expect(controller.debugWindow == nil)
        #expect(controller.debugHostingController == nil)
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
