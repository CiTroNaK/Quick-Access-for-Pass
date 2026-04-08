import Foundation
import AppKit
import os

/// Observes NSWorkspace.didWakeNotification, debounces by `debounceSeconds`
/// for the system to settle, then invokes the callback. Teardown is explicit
/// via `stop()` — call from applicationWillTerminate or when dropping the
/// observer deliberately.
@MainActor
final class WakeObserver {
    private var observer: NSObjectProtocol?
    private var pendingWakeTask: Task<Void, Never>?
    private let onWake: @MainActor () async -> Void
    private let debounceSeconds: Double

    init(debounceSeconds: Double = 2.0, onWake: @escaping @MainActor () async -> Void) {
        self.debounceSeconds = debounceSeconds
        self.onWake = onWake
    }

    func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                self?.schedulePending()
            }
        }
    }

    func stop() {
        pendingWakeTask?.cancel()
        pendingWakeTask = nil
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
    }

    #if DEBUG
    /// Test-only: drives the debounce code path without a real NSWorkspace
    /// notification. Returns the pending debounce Task so tests can await it
    /// deterministically instead of racing wall-clock.
    func simulateWakeForTesting() -> Task<Void, Never>? {
        schedulePending()
        return pendingWakeTask
    }
    #endif

    private func schedulePending() {
        pendingWakeTask?.cancel()
        let debounce = debounceSeconds
        pendingWakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(debounce))
            guard !Task.isCancelled, let self else { return }
            AppLogger.coordinator.notice("wake debounce expired — invoking onWake")
            await self.onWake()
        }
    }
}
