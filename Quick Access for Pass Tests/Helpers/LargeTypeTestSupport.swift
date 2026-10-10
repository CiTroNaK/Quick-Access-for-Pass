import AppKit
import SwiftUI
import Testing
@testable import Quick_Access_for_Pass

/// Exercises the real native phases without keying/activating a visible owner window.
@MainActor
func headlessLargeTypeActions(
    controller: LargeTypeWindowController = LargeTypeWindowController(presentationMode: .headless),
    onPresented: @escaping @MainActor @Sendable (LargeTypeDisplay) -> Void = { _ in }
) -> LargeTypePresentationActions {
    LargeTypePresentationActions(
        prepare: { controller.prepare(display: $0, relativeTo: nil) },
        activate: { try controller.activatePreparedWindow($0) },
        present: { try controller.present($0) },
        complete: { prepared in
            let display = (prepared.window.contentViewController as? NSHostingController<LargeTypeView>)?.rootView.display
            controller.completePresentation(prepared)
            if let display { onPresented(display) }
        },
        discard: { controller.discard($0) }
    )
}

/// Shared composed assertion for both panel ownership and Settings key handling.
@MainActor
func assertPreparedLargeTypeOwnershipBeforeKeyNotification() throws {
    let panel = PanelController(frontmostApplication: { nil }, activateApplication: { _ in })
    let largeType = LargeTypeWindowController(presentationMode: .headless)
    let delegate = AppDelegate()
    delegate.panelController = panel
    var events: [String] = []
    var auxiliaryCloses = 0
    panel.onHideAuxiliary = { auxiliaryCloses += 1; largeType.close() }
    largeType.onWindowPrepared = { window in events.append("register"); panel.registerOwnedWindow(window) }
    largeType.onPreparationDiscarded = { panel.unregisterOwnedWindow($0) }
    largeType.onWindowClosed = { panel.unregisterOwnedWindow($0) }
    largeType.onWindowShown = { _ in events.append("shown") }
    panel.show()
    defer { panel.hide(); largeType.close() }
    let prepared = largeType.prepare(display: try LargeTypeDisplay(validating: "FIXTURE"), relativeTo: nil)
    events.append("activate")
    try largeType.activatePreparedWindow(prepared)
    #expect(prepared.window.contentViewController == nil)
    #expect(panel.isOwnWindow(prepared.window))
    delegate.keyWindowProvider = { prepared.window }
    delegate.handleWindowDidBecomeKeyNotification(Notification(name: NSWindow.didBecomeKeyNotification, object: prepared.window))
    #expect(panel.isVisible)
    #expect(auxiliaryCloses == 0)
    try largeType.present(prepared)
    events.append("present")
    largeType.completePresentation(prepared)
    #expect(events == ["register", "activate", "present", "shown"])
    #expect(panel.isOwnWindow(prepared.window))
    largeType.close()
    #expect(!panel.isOwnWindow(prepared.window))
}
