import AppKit
import SwiftUI

// MARK: - Toast

private struct ToastView: View {
    let message: String
    let onDismissed: () -> Void
    @State private var opacity: Double = 0
    @State private var slideOffset: Double = 6

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .font(.subheadline)
            Text(message)
                .font(.subheadline)
                .fontWeight(.medium)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .fixedSize()
        .background(.ultraThickMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.3), radius: 14, y: 4)
        .opacity(opacity)
        .offset(y: slideOffset)
        .onAppear {
            withAnimation(.spring(duration: 0.3, bounce: 0.25)) {
                opacity = 1
                slideOffset = 0
            }
            Task {
                try? await Task.sleep(for: .milliseconds(1800))
                withAnimation(.easeIn(duration: 0.22)) {
                    opacity = 0
                    slideOffset = 4
                }
                try? await Task.sleep(for: .milliseconds(250))
                onDismissed()
            }
        }
    }
}

@MainActor
final class ToastWindowController {
    private var panel: NSPanel?
    // Retained so the controller stays alive while its view is the panel's content view.
    private var hostingController: NSHostingController<ToastView>?

    func show(message: String = String(localized: "Copied to clipboard")) {
        panel?.orderOut(nil)
        panel = nil
        hostingController = nil

        // panel and coordinate locals
        // swiftlint:disable identifier_name
        let p = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: true
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        panel = p

        let hc = NSHostingController(rootView: ToastView(message: message, onDismissed: { [weak self] in
            self?.panel?.orderOut(nil)
            self?.panel = nil
            self?.hostingController = nil
        }))
        hostingController = hc

        // sizeThatFits works reliably now that glassEffect (the constraint-loop trigger) is gone.
        let size = hc.sizeThatFits(in: CGSize(width: 1000, height: 1000))
        p.contentView = hc.view

        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            let x = sf.midX - size.width / 2
            // Position above the Dock with enough clearance for the shadow.
            let y = sf.minY + 56
            p.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        }

        p.orderFront(nil)
        // swiftlint:enable identifier_name
    }
}

// MARK: - Panel Controller

@MainActor
final class PanelController {
    private let panel: QuickAccessPanel
    private var eventMonitor: Any?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var ownedAuxiliaryWindows: [ObjectIdentifier: WeakWindowBox] = [:]
    /// Brief guard to ignore spurious `didBecomeKeyNotification` during `show()`.
    private(set) var isShowingTransition = false

    var isVisible: Bool { panel.isVisible }
    var windowForPresentation: NSWindow { panel }
    func isOwnWindow(_ window: NSWindow) -> Bool {
        purgeReleasedOwnedWindows()
        return window === panel || ownedAuxiliaryWindows[ObjectIdentifier(window)]?.window === window
    }
    var onShow: (() -> Void)?
    var onHide: (() -> Void)?
    /// Called immediately before the panel hides, so auxiliary windows
    /// owned by this panel session (e.g. Large Type) can dismiss themselves.
    var onHideAuxiliary: (() -> Void)?
    /// Optional predicate consulted at the top of `hide()`. Return `true`
    /// to block the hide. Used to keep the panel anchored while an
    /// LAContext auth sheet is on screen.
    var shouldBlockHide: (() -> Bool)?
    /// Return `true` to consume the event, `false` to pass it through.
    var onKeyDown: ((UInt16, NSEvent.ModifierFlags) -> Bool)?

    init() {
        self.panel = QuickAccessPanel()
    }

    func registerOwnedWindow(_ window: NSWindow) {
        ownedAuxiliaryWindows[ObjectIdentifier(window)] = WeakWindowBox(window: window)
    }

    func unregisterOwnedWindow(_ window: NSWindow) {
        ownedAuxiliaryWindows.removeValue(forKey: ObjectIdentifier(window))
    }

    func setContent<V: View>(_ view: V) {
        let hostingView = NSHostingView(rootView: view)
        panel.contentView = hostingView
    }

    func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        previousApp = NSWorkspace.shared.frontmostApplication
        isShowingTransition = true
        panel.centerOnScreen()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
        onShow?()

        // Allow the activation to settle before honoring didBecomeKeyNotification.
        // System windows (e.g., SPRoundedWindow from SafariPlatformSupport) can briefly
        // become key during app activation, so we need a short delay, not just next run loop.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.isShowingTransition = false
        }

        // Monitor for clicks outside the panel to dismiss
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.hide()
            }
        }

        // Local key monitor for configurable shortcuts. Only modifier-bearing
        // events reach onKeyDown so plain typing in the search field bypasses
        // the match loop. Because shift-letter keystrokes also reach us here,
        // every shortcut handler MUST gate on detailItem != nil — otherwise
        // a shift-only binding (e.g. the default ⇧Return for Large Type)
        // would fire while the user is typing in the search field.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard !mods.isEmpty else { return event }
            if self?.onKeyDown?(event.keyCode, mods) == true {
                return nil // consumed
            }
            return event
        }
    }

    func hide() {
        if shouldBlockHide?() == true { return }
        isShowingTransition = false
        onHideAuxiliary?()
        ownedAuxiliaryWindows.removeAll()
        panel.orderOut(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        previousApp?.activate()
        previousApp = nil
        onHide?()
    }

    private func purgeReleasedOwnedWindows() {
        ownedAuxiliaryWindows = ownedAuxiliaryWindows.filter { $0.value.window != nil }
    }
}

private final class WeakWindowBox {
    weak var window: NSWindow?

    init(window: NSWindow) {
        self.window = window
    }
}
