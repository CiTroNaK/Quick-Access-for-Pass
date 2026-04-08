import AppKit

final class QuickAccessPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: true
        )

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true

        // Allow the panel to become key (for keyboard input)
        becomesKeyOnlyIfNeeded = false
    }

    override var canBecomeKey: Bool { true }

    func centerOnScreen() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        // coordinate locals
        // swiftlint:disable identifier_name
        let x = screenFrame.midX - frame.width / 2
        let y = screenFrame.midY - frame.height / 2 + screenFrame.height * 0.15
        // swiftlint:enable identifier_name
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
