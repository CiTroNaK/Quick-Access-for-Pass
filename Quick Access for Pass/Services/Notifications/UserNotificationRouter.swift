import Foundation
import UserNotifications

nonisolated struct NotificationUserInfo: Sendable, Equatable {
    let host: String?
    let keyNames: [String]
    let appIdentifiers: [String]
    let appTeamIDs: [String]

    init(raw: [AnyHashable: Any]) {
        host = raw["host"] as? String
        keyNames = raw["keyNames"] as? [String] ?? []
        appIdentifiers = raw["appIdentifiers"] as? [String] ?? []
        appTeamIDs = raw["appTeamIDs"] as? [String] ?? []
    }
}

nonisolated struct NotificationActionContext: Sendable, Equatable {
    let actionIdentifier: String
    let userInfo: NotificationUserInfo
    let requestIdentifier: String
}

private nonisolated struct NotificationCompletion: @unchecked Sendable {
    let handler: () -> Void

    func call() {
        handler()
    }
}

@MainActor
protocol UserNotificationActionHandling: AnyObject {
    func handleNotificationAction(_ context: NotificationActionContext) async -> Bool
}

@MainActor
protocol UserNotificationCategoryRegistering: AnyObject {
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
}

extension UNUserNotificationCenter: UserNotificationCategoryRegistering {}

@MainActor
final class UserNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    private var handlers: [String: any UserNotificationActionHandling] = [:]
    private var categories: [String: UNNotificationCategory] = [:]
    private let notificationCenter: UNUserNotificationCenter
    private let categoryRegistrar: any UserNotificationCategoryRegistering

    init(
        notificationCenter: UNUserNotificationCenter = .current(),
        categoryRegistrar: (any UserNotificationCategoryRegistering)? = nil,
        assignAsDelegate: Bool = true
    ) {
        self.notificationCenter = notificationCenter
        self.categoryRegistrar = categoryRegistrar ?? notificationCenter
        super.init()
        if assignAsDelegate {
            notificationCenter.delegate = self
        }
    }

    func register(_ handler: any UserNotificationActionHandling, forCategoryIdentifier categoryIdentifier: String) {
        handlers[categoryIdentifier] = handler
    }

    func registerCategory(_ category: UNNotificationCategory) {
        categories[category.identifier] = category
        categoryRegistrar.setNotificationCategories(Set(categories.values))
    }

    func dispatch(
        categoryIdentifier: String,
        actionIdentifier: String,
        rawUserInfo: [AnyHashable: Any],
        requestIdentifier: String
    ) async -> Bool {
        guard let handler = handlers[categoryIdentifier] else { return false }
        let context = NotificationActionContext(
            actionIdentifier: actionIdentifier,
            userInfo: NotificationUserInfo(raw: rawUserInfo),
            requestIdentifier: requestIdentifier
        )
        return await handler.handleNotificationAction(context)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let categoryIdentifier = response.notification.request.content.categoryIdentifier
        let actionIdentifier = response.actionIdentifier
        let requestIdentifier = response.notification.request.identifier
        let context = NotificationActionContext(
            actionIdentifier: actionIdentifier,
            userInfo: NotificationUserInfo(raw: response.notification.request.content.userInfo),
            requestIdentifier: requestIdentifier
        )
        let completion = NotificationCompletion(handler: completionHandler)

        Task { @MainActor in
            guard let handler = self.handlers[categoryIdentifier] else {
                completion.call()
                return
            }
            _ = await handler.handleNotificationAction(context)
            completion.call()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
