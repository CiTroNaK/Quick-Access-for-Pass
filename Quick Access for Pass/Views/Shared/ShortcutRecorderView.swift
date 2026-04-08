import AppKit
import SwiftUI

// MARK: - SwiftUI wrapper

struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var keyCode: Int
    @Binding var modifiers: Int

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        view.onShortcutChanged = { code, mods in
            keyCode = Int(code)
            modifiers = Int(mods.rawValue)
        }
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
        nsView.keyCode = UInt16(keyCode)
        nsView.modifiers = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        nsView.refreshDisplay()
    }
}

// MARK: - NSView

final class ShortcutRecorderNSView: NSView {
    var keyCode: UInt16 = 35
    var modifiers: NSEvent.ModifierFlags = [.command, .shift]
    var onShortcutChanged: ((UInt16, NSEvent.ModifierFlags) -> Void)?

    private var isRecording = false
    private var eventMonitor: Any?
    private let button: NSButton

    override init(frame: NSRect) {
        button = NSButton(title: "", target: nil, action: nil)
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        button = NSButton(title: "", target: nil, action: nil)
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(buttonClicked)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
        ])
        refreshDisplay()
    }

    @objc private func buttonClicked() {
        guard !isRecording else { cancelRecording(); return }
        isRecording = true
        button.title = String(localized: "Type shortcut…")
        button.highlight(true)

        // Announce the state change so VoiceOver users know the field is
        // now listening for keys. Without this, there is no audible
        // feedback that the recorder is active.
        NSAccessibility.post(
            element: button,
            notification: .announcementRequested,
            userInfo: [
                .announcement: String(localized: "Recording shortcut. Press keys."),
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Escape
                self.cancelRecording()
                return nil
            }
            let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard !mods.isEmpty else { return nil } // require at least one modifier
            self.keyCode = event.keyCode
            self.modifiers = mods
            self.onShortcutChanged?(event.keyCode, mods)
            self.stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        removeMonitor()
        button.highlight(false)
        refreshDisplay()
    }

    private func cancelRecording() {
        isRecording = false
        removeMonitor()
        button.highlight(false)
        refreshDisplay()
    }

    private func removeMonitor() {
        // event monitor local alias
        // swiftlint:disable:next identifier_name
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
    }

    func refreshDisplay() {
        guard !isRecording else { return }
        button.title = ShortcutFormatting.modifiersString(Int(modifiers.rawValue))
            + (ShortcutFormatting.keyCodeToString[keyCode] ?? "?")
    }
}
