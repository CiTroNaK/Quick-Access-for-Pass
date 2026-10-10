import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class LargeTypeWindowController {
    enum PresentationMode: Sendable {
        case automatic
        case visible
        case headless
    }

    private let presentationMode: PresentationMode
    private var window: NSWindow?
    private var hostingController: NSHostingController<LargeTypeView>?
    private weak var previousKeyWindow: NSWindow?
    private weak var preparation: PreparedLargeTypePresentation?
    var onWindowPrepared: ((NSWindow) -> Void)?
    var onPreparationDiscarded: ((NSWindow) -> Void)?
    var onWindowShown: ((NSWindow) -> Void)?
    var onWindowClosed: ((NSWindow) -> Void)?

    init(presentationMode: PresentationMode = .automatic) {
        self.presentationMode = presentationMode
    }

    #if DEBUG
    var debugWindow: NSWindow? { window }
    var debugHostingController: NSViewController? { hostingController }
    #endif

    func show(display: LargeTypeDisplay, relativeTo panel: NSWindow?) {
        let prepared = prepare(display: display, relativeTo: panel)
        defer { discard(prepared) }
        do {
            try activatePreparedWindow(prepared)
            try present(prepared)
            completePresentation(prepared)
        } catch {
            // Unrelated callers have no secret-action error presentation.
        }
    }

    func prepare(display: LargeTypeDisplay, relativeTo panel: NSWindow?) -> PreparedLargeTypePresentation {
        if let preparation { discard(preparation) }
        let visibleFrame = panel?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let layout = LargeTypeView.Layout.bestFit(tileCount: display.tiles.count, visibleFrame: visibleFrame)
        let ownsNewWindow = window == nil
        let shell = window ?? makeWindow()
        let hosting = NSHostingController(rootView: LargeTypeView(
            display: display, layout: layout, onClose: { [weak self] in self?.close() }
        ))
        // Force view construction while unattached, outside release synchronization.
        hosting.view.setFrameSize(layout.contentSize(for: display.tiles.count))
        let prepared = PreparedLargeTypePresentation(window: shell, hostingController: hosting,
            layout: layout, previousPanel: panel, ownsNewWindow: ownsNewWindow, owner: self)
        preparation = prepared
        if ownsNewWindow {
            prepared.ownsRegistration = true
            onWindowPrepared?(shell)
        }
        // Registration may synchronously close/discard the shell.
        guard prepared.state == .prepared else { return prepared }
        (shell as? LargeTypePanel)?.onCloseCommand = { [weak self] in self?.close() }
        shell.setContentSize(layout.contentSize(for: display.tiles.count))
        center(shell, relativeTo: panel, visibleFrame: visibleFrame)
        return prepared
    }

    func activatePreparedWindow(_ prepared: PreparedLargeTypePresentation) throws {
        try requirePrepared(prepared)
        if shouldPresentVisibly {
            prepared.window.makeKeyAndOrderFront(nil)
            // Key notifications can discard the preparation. Never reactivate it.
            try requirePrepared(prepared)
            NSApp.activate()
        }
        try requirePrepared(prepared)
    }

    /// The sole secret effect. The already-loaded view has no onAppear/task,
    /// delegate, ownership, activation or completion callbacks. Sizing and key
    /// notifications happen in preparation/activation, never in this attachment.
    func present(_ prepared: PreparedLargeTypePresentation) throws {
        try requirePrepared(prepared)
        guard let hosting = prepared.hostingController else { throw CancellationError() }
        prepared.window.contentViewController = hosting
        window = prepared.window
        hostingController = hosting
        previousKeyWindow = prepared.previousPanel
        prepared.state = .presented
        preparation = nil
    }

    func completePresentation(_ prepared: PreparedLargeTypePresentation) {
        guard prepared.owner === self, prepared.state == .presented else { return }
        prepared.state = .completed
        prepared.ownsRegistration = false // Ordinary close now owns unregistering.
        prepared.hostingController = nil
        onWindowShown?(prepared.window)
    }

    func discard(_ prepared: PreparedLargeTypePresentation) {
        guard prepared.owner === self, prepared.state == .prepared else { return }
        prepared.state = .discarded
        prepared.hostingController = nil
        if preparation === prepared { preparation = nil }
        if prepared.ownsNewWindow {
            prepared.window.orderOut(nil)
            (prepared.window as? LargeTypePanel)?.onCloseCommand = nil
            if prepared.ownsRegistration {
                prepared.ownsRegistration = false
                onPreparationDiscarded?(prepared.window)
            }
        }
    }

    private func requirePrepared(_ prepared: PreparedLargeTypePresentation) throws {
        guard prepared.owner === self, prepared.state == .prepared,
              preparation === prepared,
              prepared.ownsNewWindow || window === prepared.window else { throw CancellationError() }
    }

    func close() {
        if let preparation { discard(preparation) }
        if let window {
            onWindowClosed?(window)
            window.orderOut(nil)
        }
        window = nil
        hostingController = nil
        if shouldPresentVisibly, let previous = previousKeyWindow, previous.isVisible {
            previous.makeKey()
        }
        previousKeyWindow = nil
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

    private func makeWindow() -> LargeTypePanel {
        let panel = LargeTypePanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 320),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.title = String(localized: "Large Type")
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        return panel
    }

    private func center(_ window: NSWindow, relativeTo panel: NSWindow?, visibleFrame: NSRect) {
        let centeredFrame: NSRect
        if let panel {
            let frame = panel.frame
            centeredFrame = NSRect(
                x: frame.midX - window.frame.width / 2,
                y: frame.midY - window.frame.height / 2,
                width: window.frame.width,
                height: window.frame.height
            )
        } else {
            centeredFrame = NSRect(
                x: visibleFrame.midX - window.frame.width / 2,
                y: visibleFrame.midY - window.frame.height / 2,
                width: window.frame.width,
                height: window.frame.height
            )
        }

        let clampedOrigin = NSPoint(
            x: min(max(centeredFrame.origin.x, visibleFrame.minX), visibleFrame.maxX - centeredFrame.width),
            y: min(max(centeredFrame.origin.y, visibleFrame.minY), visibleFrame.maxY - centeredFrame.height)
        )
        window.setFrameOrigin(clampedOrigin)
    }
}

private final class LargeTypePanel: NSPanel {
    var onCloseCommand: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Return, kVK_Escape, kVK_ANSI_KeypadEnter:
            onCloseCommand?()
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCloseCommand?()
    }
}
