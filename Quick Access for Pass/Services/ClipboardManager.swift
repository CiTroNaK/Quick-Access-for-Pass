import AppKit
import Foundation

@MainActor
final class ClipboardManager {
    private let autoClearSeconds: TimeInterval
    private let pasteboard: NSPasteboard
    private let userDefaults: UserDefaults
    private var clearTask: Task<Void, Never>?
    private var lastChangeCount: Int = 0

    /// Test-only mirror of the most recent `copy(_:label:)` payload. Never
    /// serialized; never used by production code paths. Set alongside the
    /// pasteboard write so tests have a deterministic anchor.
    #if DEBUG
    private(set) var lastCopiedValue: String?
    #endif

    /// Called after a successful copy, after a short delay so the panel can close first.
    /// The string argument is the toast message to display.
    var onCopy: ((String) -> Void)?

    init(
        autoClearSeconds: TimeInterval = 30,
        pasteboard: NSPasteboard = .general,
        userDefaults: UserDefaults = .standard
    ) {
        self.autoClearSeconds = autoClearSeconds
        self.pasteboard = pasteboard
        self.userDefaults = userDefaults
    }

    func copy(_ text: String, label: String = String(localized: "Copied to clipboard")) {
        pasteboard.clearContents()
        pasteboard.writeObjects([text as NSString])
        #if DEBUG
        self.lastCopiedValue = text
        #endif
        // If the user hasn't opted out, mark as concealed so clipboard managers
        // (Alfred, Pastebot, Pasta, etc.) skip storing this entry in history.
        if userDefaults.bool(forKey: DefaultsKey.concealFromClipboardManagers) {
            pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }
        lastChangeCount = pasteboard.changeCount

        scheduleClear()

        // Delay slightly so the quick-access panel finishes closing before the toast appears.
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            onCopy?(label)
        }
    }

    func clearOnTermination() {
        clearTask?.cancel()
        pasteboard.clearContents()
    }

    private func scheduleClear() {
        clearTask?.cancel()

        guard autoClearSeconds > 0 else { return }

        let expectedChangeCount = lastChangeCount
        let pb = pasteboard
        let seconds = autoClearSeconds
        clearTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            if pb.changeCount == expectedChangeCount {
                pb.clearContents()
            }
        }
    }
}
