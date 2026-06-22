import Accessibility
import AppKit
import SwiftUI

@MainActor
final class SyncIssueWindowController {
    enum PresentationMode: Sendable {
        case automatic
        case visible
        case headless
    }

    struct Actions {
        let copyReport: @MainActor @Sendable (QuickAccessSyncIssuePresentation) -> Void
        let copyAndReport: @MainActor @Sendable (QuickAccessSyncIssuePresentation) -> Void
        let copySkippedItemCommand: @MainActor @Sendable (SkippedSyncItem) -> Void
        let dismissIssue: @MainActor @Sendable (QuickAccessSyncIssuePresentation) -> Void
    }

    private let actions: Actions
    private let presentationMode: PresentationMode
    private var window: SyncIssuePanel?
    private var hostingController: NSHostingController<SyncIssueWindowView>?
    private(set) var state: SyncIssueWindowState = .empty
    #if DEBUG
    private var positioningCount = 0
    #endif

    init(actions: Actions, presentationMode: PresentationMode = .automatic) {
        self.actions = actions
        self.presentationMode = presentationMode
    }

    #if DEBUG
    var debugWindow: NSWindow? { window }
    var debugState: SyncIssueWindowState { state }
    var debugPositioningCount: Int { positioningCount }

    func debugCopyReport() {
        copyReportForCurrentState()
    }

    func debugDismissIssue() {
        dismissIssueForCurrentState()
    }
    #endif

    func show(presentation: QuickAccessSyncIssuePresentation?, relativeTo parentWindow: NSWindow?) {
        state = presentation.map(SyncIssueWindowState.current) ?? .empty
        render(relativeTo: parentWindow, announcesChange: true, positionsWindow: true)
    }

    func show(presentation: QuickAccessSyncIssuePresentation, relativeTo parentWindow: NSWindow?) {
        show(presentation: Optional(presentation), relativeTo: parentWindow)
    }

    func syncIssueDidChange(_ presentation: QuickAccessSyncIssuePresentation?) {
        guard window != nil else { return }
        if let presentation {
            state = .current(presentation)
        } else if case .current(let previous) = state {
            state = .resolved(previous)
        } else if case .resolved = state {
            return
        } else {
            state = .empty
        }
        render(relativeTo: nil, announcesChange: true, positionsWindow: false)
    }

    func close() {
        if let window {
            window.orderOut(nil)
        }
        window = nil
        hostingController = nil
    }

    private func render(
        relativeTo parentWindow: NSWindow?,
        announcesChange: Bool,
        positionsWindow: Bool
    ) {
        let window = makeOrReuseWindow()
        let view = SyncIssueWindowView(
            state: state,
            copyReport: { [weak self] in self?.copyReportForCurrentState() },
            copyAndReport: { [weak self] in self?.copyAndReportForCurrentState() },
            copySkippedItemCommand: actions.copySkippedItemCommand,
            dismiss: { [weak self] in self?.dismissIssueForCurrentState() },
            close: { [weak self] in self?.close() }
        )
        let hostingController = NSHostingController(rootView: view)
        self.hostingController = hostingController
        window.contentViewController = hostingController
        window.onCloseCommand = { [weak self] in self?.close() }
        if positionsWindow {
            #if DEBUG
            positioningCount += 1
            #endif
            if let parentWindow {
                center(window, relativeTo: parentWindow)
            } else {
                centerOnMainScreen(window)
            }
        }
        if shouldPresentVisibly {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        if announcesChange {
            AccessibilityNotification.Announcement(state.accessibilityAnnouncement).post()
        }
    }

    private func copyReportForCurrentState() {
        guard let presentation = state.presentation else { return }
        actions.copyReport(presentation)
    }

    private func copyAndReportForCurrentState() {
        guard let presentation = state.presentation else { return }
        actions.copyAndReport(presentation)
    }

    private func dismissIssueForCurrentState() {
        guard let presentation = state.presentation else { return }
        actions.dismissIssue(presentation)
        close()
    }

    private var shouldPresentVisibly: Bool {
        switch presentationMode {
        case .visible:
            true
        case .headless:
            false
        case .automatic:
            ProcessInfo.processInfo.environment["XCTestBundlePath"] == nil
        }
    }

    private func makeOrReuseWindow() -> SyncIssuePanel {
        if let window {
            return window
        }

        let panel = SyncIssuePanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.title = String(localized: "Sync Errors", comment: "Title for sync diagnostics window.")
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        self.window = panel
        return panel
    }

    private func center(_ window: NSWindow, relativeTo parentWindow: NSWindow) {
        let frame = parentWindow.frame
        let origin = NSPoint(
            x: frame.midX - window.frame.width / 2,
            y: frame.midY - window.frame.height / 2
        )
        window.setFrameOrigin(origin)
    }

    private func centerOnMainScreen(_ window: NSWindow) {
        guard let visibleFrame = NSScreen.main?.visibleFrame else { return }
        window.setFrameOrigin(NSPoint(
            x: visibleFrame.midX - window.frame.width / 2,
            y: visibleFrame.midY - window.frame.height / 2
        ))
    }
}

private final class SyncIssuePanel: NSPanel {
    var onCloseCommand: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCloseCommand?()
    }

    override func close() {
        onCloseCommand?()
    }
}
