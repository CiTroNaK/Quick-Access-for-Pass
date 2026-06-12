import AppKit
import Foundation

@MainActor
protocol SystemLockDistributedNotificationCenter: AnyObject {
    func addObserver(
        _ observer: Any,
        selector: Selector,
        name: Notification.Name?,
        object: String?,
        suspensionBehavior: DistributedNotificationCenter.SuspensionBehavior
    )
    func removeObserver(_ observer: Any)
}

extension DistributedNotificationCenter: SystemLockDistributedNotificationCenter {}

/// Observes macOS notifications that indicate the user session is leaving
/// active use, the system is going to sleep, or the screen has been locked,
/// then invokes a main-actor callback so Quick Access can lock itself.
@MainActor
final class SystemLockObserver: NSObject {
    static let screenIsLockedNotification = Notification.Name("com.apple.screenIsLocked")

    private let workspaceNotificationCenter: NotificationCenter
    private let distributedNotificationCenter: any SystemLockDistributedNotificationCenter
    private let onSystemLock: @MainActor () -> Void
    private var workspaceObservers: [NSObjectProtocol] = []
    private var isObservingDistributedNotifications = false

    init(
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        distributedNotificationCenter: any SystemLockDistributedNotificationCenter = DistributedNotificationCenter.default(),
        onSystemLock: @escaping @MainActor () -> Void
    ) {
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.distributedNotificationCenter = distributedNotificationCenter
        self.onSystemLock = onSystemLock
        super.init()
    }

    func start() {
        guard workspaceObservers.isEmpty, !isObservingDistributedNotifications else { return }
        workspaceObservers = [
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.willSleepNotification,
        ].map { name in
            workspaceNotificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.onSystemLock()
                }
            }
        }

        distributedNotificationCenter.addObserver(
            self,
            selector: #selector(handleDistributedSystemLockNotification(_:)),
            name: Self.screenIsLockedNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        isObservingDistributedNotifications = true
    }

    func stop() {
        for observer in workspaceObservers {
            workspaceNotificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        if isObservingDistributedNotifications {
            distributedNotificationCenter.removeObserver(self)
            isObservingDistributedNotifications = false
        }
    }

    @objc private nonisolated func handleDistributedSystemLockNotification(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.onSystemLock()
        }
    }

    #if DEBUG
    func simulateSessionDidResignActiveForTesting() {
        onSystemLock()
    }

    func simulateWillSleepForTesting() {
        onSystemLock()
    }

    func simulateScreenIsLockedForTesting() {
        onSystemLock()
    }
    #endif
}
