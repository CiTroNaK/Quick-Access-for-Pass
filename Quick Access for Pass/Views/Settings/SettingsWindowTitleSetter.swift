import SwiftUI

struct SettingsWindowTitleSetter: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = WindowTitleObserverView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowTitleObserverView: NSView {
    private var observation: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        let settingsTitle = String(localized: "Quick Access for Pass Settings")
        window.title = settingsTitle
        observation = window.observe(\.title, options: [.new]) { win, _ in
            Task { @MainActor in
                if win.title != settingsTitle {
                    win.title = settingsTitle
                }
            }
        }
    }
}
