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
    private var window: LargeTypePanel?
    private var hostingController: NSHostingController<LargeTypeView>?
    private weak var previousKeyWindow: NSWindow?
    var onWindowShown: ((NSWindow) -> Void)?
    var onWindowClosed: ((NSWindow) -> Void)?

    init(presentationMode: PresentationMode = .automatic) {
        self.presentationMode = presentationMode
    }

    #if DEBUG
    var debugWindow: NSWindow? { window }
    #endif

    func show(display: LargeTypeDisplay, relativeTo panel: NSWindow?) {
        let visibleFrame =
            panel?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let layout = LargeTypeView.Layout.bestFit(tileCount: display.tiles.count, visibleFrame: visibleFrame)
        let window = makeOrReuseWindow()
        previousKeyWindow = panel

        let hostingController = NSHostingController(
            rootView: LargeTypeView(
                display: display,
                layout: layout,
                onClose: { [weak self] in self?.close() }
            )
        )
        self.hostingController = hostingController
        window.contentViewController = hostingController
        window.onCloseCommand = { [weak self] in self?.close() }
        window.setContentSize(layout.contentSize(for: display.tiles.count))
        center(window, relativeTo: panel, visibleFrame: visibleFrame)
        onWindowShown?(window)
        if shouldPresentVisibly {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    func close() {
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

    private func makeOrReuseWindow() -> LargeTypePanel {
        if let window {
            return window
        }

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
        self.window = panel
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
