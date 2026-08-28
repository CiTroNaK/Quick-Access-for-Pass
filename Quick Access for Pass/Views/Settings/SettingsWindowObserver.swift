import SwiftUI

struct SettingsWindowObserver: NSViewRepresentable {
    let onWindowAvailable: @MainActor (NSWindow) -> Void

    init(onWindowAvailable: @escaping @MainActor (NSWindow) -> Void = { _ in }) {
        self.onWindowAvailable = onWindowAvailable
    }

    func makeNSView(context: Context) -> NSView {
        SettingsWindowObserverView(onWindowAvailable: onWindowAvailable)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Reports the containing Settings window without modifying its system-managed state.
final class SettingsWindowObserverView: NSView {
    private let onWindowAvailable: @MainActor (NSWindow) -> Void

    init(onWindowAvailable: @escaping @MainActor (NSWindow) -> Void) {
        self.onWindowAvailable = onWindowAvailable
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        onWindowAvailable(window)
    }
}
