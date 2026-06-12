import AppKit
import Foundation

/// Observes public macOS workspace notifications that indicate the user
/// session is leaving active use or the system is going to sleep, then invokes
/// a main-actor callback so Quick Access can lock itself.
@MainActor
final class SystemLockObserver {
    private let notificationCenter: NotificationCenter
    private let onSystemLock: @MainActor () -> Void
    private var observers: [NSObjectProtocol] = []

    init(
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        onSystemLock: @escaping @MainActor () -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.onSystemLock = onSystemLock
    }

    func start() {
        guard observers.isEmpty else { return }
        observers = [
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.willSleepNotification,
        ].map { name in
            notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.onSystemLock()
                }
            }
        }
    }

    func stop() {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    #if DEBUG
    func simulateSessionDidResignActiveForTesting() {
        onSystemLock()
    }

    func simulateWillSleepForTesting() {
        onSystemLock()
    }
    #endif
}
