import Foundation
import SwiftUI
import UserNotifications

@MainActor
protocol PassCLILoginNotificationPosting: AnyObject {
    func postLoggedOutNotification()
    func postResultNotification(title: String, body: String, categoryIdentifier: String?)
}

@MainActor
final class LivePassCLILoginNotificationPoster: PassCLILoginNotificationPosting {
    private let notificationCenter: UNUserNotificationCenter

    init(notificationCenter: UNUserNotificationCenter = .current()) {
        self.notificationCenter = notificationCenter
    }

    func postLoggedOutNotification() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Proton Pass CLI is logged out")
        content.body = String(localized: "Log in to continue syncing and using Quick Access.")
        content.categoryIdentifier = PassCLILoginNotifier.categoryIdentifier
        notificationCenter.add(UNNotificationRequest(
            identifier: PassCLILoginNotifier.notificationIdentifier,
            content: content,
            trigger: nil
        ))
    }

    func postResultNotification(title: String, body: String, categoryIdentifier: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let categoryIdentifier {
            content.categoryIdentifier = categoryIdentifier
        }
        notificationCenter.add(UNNotificationRequest(
            identifier: "pass-cli-login-result-\(UUID().uuidString)",
            content: content,
            trigger: nil
        ))
    }
}

@MainActor
final class PassCLILoginNotifier: UserNotificationActionHandling, PassCLIHealthTransitionHandling {
    static let categoryIdentifier = "PASS_CLI_LOGIN"
    static let loginActionIdentifier = "LOGIN"
    static let notificationIdentifier = "pass-cli-login-required"

    private let poster: any PassCLILoginNotificationPosting
    private let startLogin: @MainActor @Sendable () -> Void
    private var hasPostedForCurrentLogout = false
    private var isLoggedOutEpisodeActive = false

    init(
        notificationRouter: UserNotificationRouter?,
        poster: any PassCLILoginNotificationPosting = LivePassCLILoginNotificationPoster(),
        startLogin: @escaping @MainActor @Sendable () -> Void
    ) {
        self.poster = poster
        self.startLogin = startLogin
        let login = UNNotificationAction(identifier: Self.loginActionIdentifier, title: String(localized: "Log In"), options: [])
        let category = UNNotificationCategory(identifier: Self.categoryIdentifier, actions: [login], intentIdentifiers: [])
        notificationRouter?.registerCategory(category)
        notificationRouter?.register(self, forCategoryIdentifier: Self.categoryIdentifier)
    }

    func requestAuthorizationIfNeeded(notificationCenter: UNUserNotificationCenter = .current()) {
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func handleCLIHealthTransition(to health: PassCLIHealth) {
        switch health {
        case .notLoggedIn:
            isLoggedOutEpisodeActive = true
            guard hasPostedForCurrentLogout == false else { return }
            hasPostedForCurrentLogout = true
            poster.postLoggedOutNotification()
        case .ok:
            isLoggedOutEpisodeActive = false
            hasPostedForCurrentLogout = false
        case .notInstalled, .failed:
            isLoggedOutEpisodeActive = false
        }
    }

    func handleLoginResult(_ result: PassCLILoginResult) {
        let title: String
        let body: String
        let categoryIdentifier: String?
        switch result {
        case .succeeded:
            title = String(localized: "Proton Pass CLI connected")
            body = String(localized: "Quick Access is syncing your vaults.")
            categoryIdentifier = nil
        case .failed:
            title = String(localized: "Proton Pass CLI login failed")
            body = String(localized: "Pass CLI login did not complete. Open Settings → Pass CLI to retry.")
            categoryIdentifier = Self.categoryIdentifier
        }
        AccessibilityNotification.Announcement("\(title). \(body)").post()
        poster.postResultNotification(title: title, body: body, categoryIdentifier: categoryIdentifier)
    }

    func handlePATLoginFailure(_ message: String) {
        let title = String(localized: "Personal access token login failed")
        let body = String(localized: "Replace the saved token or log in normally from Settings → Pass CLI.")
        AccessibilityNotification.Announcement("\(title). \(body)").post()
        poster.postResultNotification(
            title: title,
            body: body,
            categoryIdentifier: Self.categoryIdentifier
        )
    }

    func handleNotificationAction(_ context: NotificationActionContext) async -> Bool {
        guard context.actionIdentifier == Self.loginActionIdentifier else { return false }
        guard isLoggedOutEpisodeActive || context.requestIdentifier.hasPrefix("pass-cli-login-result") else { return false }
        startLogin()
        return true
    }
}
