import AppKit
import Foundation

@MainActor
protocol ClipboardScheduledWork {
    /// Cancels scheduled clipboard work before it runs.
    func cancel()
}

@MainActor
protocol ClipboardScheduling {
    /// Schedules clipboard work to run after a delay.
    @discardableResult
    func schedule(
        after delay: Duration,
        operation: @escaping @MainActor () -> Void
    ) -> ClipboardScheduledWork
}

@MainActor
private final class TaskClipboardScheduledWork: ClipboardScheduledWork {
    private let task: Task<Void, Never>

    init(task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }
}

@MainActor
struct TaskClipboardScheduler: ClipboardScheduling {
    /// Schedules clipboard work using Swift concurrency's cooperative cancellation.
    @discardableResult
    func schedule(
        after delay: Duration,
        operation: @escaping @MainActor () -> Void
    ) -> ClipboardScheduledWork {
        TaskClipboardScheduledWork(
            task: Task { @MainActor in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                operation()
            }
        )
    }
}

@MainActor
final class ClipboardManager {
    private let autoClearSeconds: TimeInterval
    private let pasteboard: NSPasteboard
    private let userDefaults: UserDefaults
    private let scheduler: ClipboardScheduling
    private var clearTask: ClipboardScheduledWork?
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
        userDefaults: UserDefaults = .standard,
        scheduler: ClipboardScheduling = TaskClipboardScheduler()
    ) {
        self.autoClearSeconds = autoClearSeconds
        self.pasteboard = pasteboard
        self.userDefaults = userDefaults
        self.scheduler = scheduler
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
        scheduler.schedule(after: .milliseconds(150)) { [weak self] in
            self?.onCopy?(label)
        }
    }

    func clearOnTermination() {
        clearTask?.cancel()
        pasteboard.clearContents()
    }

    @discardableResult
    func clearIfOwned() -> Bool {
        guard pasteboard.changeCount == lastChangeCount else { return false }
        clearTask?.cancel()
        clearTask = nil
        pasteboard.clearContents()
        lastChangeCount = pasteboard.changeCount
        #if DEBUG
        lastCopiedValue = nil
        #endif
        return true
    }

    private func scheduleClear() {
        clearTask?.cancel()
        clearTask = nil

        guard autoClearSeconds > 0 else { return }

        let expectedChangeCount = lastChangeCount
        clearTask = scheduler.schedule(after: .seconds(autoClearSeconds)) { [weak self] in
            guard let self else { return }
            if self.pasteboard.changeCount == expectedChangeCount {
                self.pasteboard.clearContents()
            }
        }
    }
}
