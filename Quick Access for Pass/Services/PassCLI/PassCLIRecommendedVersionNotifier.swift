import Foundation
import UserNotifications

@MainActor
protocol PassCLIUpdateNotificationPosting: AnyObject {
    func postRecommendedVersionNotification(title: String, body: String)
}

@MainActor
final class LivePassCLIUpdateNotificationPoster: PassCLIUpdateNotificationPosting {
    private let notificationCenter: UNUserNotificationCenter

    init(notificationCenter: UNUserNotificationCenter = .current()) {
        self.notificationCenter = notificationCenter
    }

    func postRecommendedVersionNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        notificationCenter.add(UNNotificationRequest(
            identifier: "pass-cli-recommended-version",
            content: content,
            trigger: nil
        ))
    }
}

@MainActor
final class PassCLIRecommendedVersionNotifier {
    private let poster: any PassCLIUpdateNotificationPosting
    private var hasPostedStartupWarning = false

    init(poster: any PassCLIUpdateNotificationPosting = LivePassCLIUpdateNotificationPoster()) {
        self.poster = poster
    }

    func postStartupWarningIfNeeded(_ warning: PassCLIRecommendedVersionWarning?) {
        guard hasPostedStartupWarning == false, let warning else { return }
        hasPostedStartupWarning = true
        poster.postRecommendedVersionNotification(
            title: String(localized: "Pass CLI update recommended"),
            body: warning.message
        )
    }
}
