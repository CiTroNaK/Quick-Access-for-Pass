import Foundation
import Testing
import UserNotifications
@testable import Quick_Access_for_Pass

@MainActor
private final class FakeLoginStarter {
    var count = 0

    func start() {
        count += 1
    }
}

@MainActor
private final class FakeLoginNotificationPoster: PassCLILoginNotificationPosting {
    var loggedOutCount = 0
    var resultMessages: [(title: String, body: String, categoryIdentifier: String?)] = []

    func postLoggedOutNotification() {
        loggedOutCount += 1
    }

    func postResultNotification(title: String, body: String, categoryIdentifier: String?) {
        resultMessages.append((title, body, categoryIdentifier))
    }
}

@MainActor
struct PassCLILoginNotifierTests {
    @Test func postsOnceForLoggedOutEpisode() {
        let poster = FakeLoginNotificationPoster()
        let notifier = PassCLILoginNotifier(notificationRouter: nil, poster: poster, startLogin: {})

        notifier.handleCLIHealthTransition(to: .notLoggedIn)
        notifier.handleCLIHealthTransition(to: .notLoggedIn)

        #expect(poster.loggedOutCount == 1)
    }

    @Test func resetsAfterHealthyTransition() {
        let poster = FakeLoginNotificationPoster()
        let notifier = PassCLILoginNotifier(notificationRouter: nil, poster: poster, startLogin: {})

        notifier.handleCLIHealthTransition(to: .notLoggedIn)
        notifier.handleCLIHealthTransition(to: .ok)
        notifier.handleCLIHealthTransition(to: .notLoggedIn)

        #expect(poster.loggedOutCount == 2)
    }

    @Test func loginActionStartsLoginAndReturnsPromptly() async {
        let starter = FakeLoginStarter()
        let notifier = PassCLILoginNotifier(notificationRouter: nil, poster: FakeLoginNotificationPoster()) {
            starter.start()
        }
        notifier.handleCLIHealthTransition(to: .notLoggedIn)

        let handled = await notifier.handleNotificationAction(NotificationActionContext(
            actionIdentifier: PassCLILoginNotifier.loginActionIdentifier,
            userInfo: NotificationUserInfo(raw: [:]),
            requestIdentifier: "pass-cli-login"
        ))

        #expect(handled == true)
        #expect(starter.count == 1)
    }

    @Test func failureNotificationUsesPassCLIWordingAndLoginActionCategory() {
        let poster = FakeLoginNotificationPoster()
        let notifier = PassCLILoginNotifier(notificationRouter: nil, poster: poster, startLogin: {})

        notifier.handleLoginResult(.failed("raw failure with https://account.proton.me/desktop/login?app=pass#payload=synthetic-test-payload"))

        #expect(poster.resultMessages.first?.body.contains("payload=") == false)
        #expect(poster.resultMessages.first?.body == "Pass CLI login did not complete. Open Settings → Pass CLI to retry.")
        #expect(poster.resultMessages.first?.categoryIdentifier == PassCLILoginNotifier.categoryIdentifier)
    }

    @Test func loginActionStartsLoginFromFailedResultNotification() async {
        let starter = FakeLoginStarter()
        let notifier = PassCLILoginNotifier(notificationRouter: nil, poster: FakeLoginNotificationPoster()) {
            starter.start()
        }

        let handled = await notifier.handleNotificationAction(NotificationActionContext(
            actionIdentifier: PassCLILoginNotifier.loginActionIdentifier,
            userInfo: NotificationUserInfo(raw: [:]),
            requestIdentifier: "pass-cli-login-result"
        ))

        #expect(handled == true)
        #expect(starter.count == 1)
    }

    @Test func patFailureNotificationUsesLoginActionCategoryAndDoesNotIncludeRawDiagnostic() {
        let poster = FakeLoginNotificationPoster()
        let notifier = PassCLILoginNotifier(notificationRouter: nil, poster: poster, startLogin: {})

        notifier.handlePATLoginFailure("invalid pst_test_token::secret")

        #expect(poster.resultMessages.first?.title == "Personal access token login failed")
        #expect(poster.resultMessages.first?.body.contains("pst_test_token") == false)
        #expect(poster.resultMessages.first?.categoryIdentifier == PassCLILoginNotifier.categoryIdentifier)
    }
}
