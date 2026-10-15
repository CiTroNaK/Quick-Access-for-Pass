import Foundation
import Testing
@testable import Quick_Access_for_Pass

@MainActor
private final class BusyNotificationPoster: PassCLILoginNotificationPosting {
    var titles: [String] = []
    var categories: [String?] = []
    var loggedOutCount = 0
    func postLoggedOutNotification() { loggedOutCount += 1 }
    func postResultNotification(title: String, body: String, categoryIdentifier: String?) {
        titles.append(title)
        categories.append(categoryIdentifier)
    }
}

@MainActor
struct PassCLIAuthenticationBusyFeedbackTests {
    @Test
    func busyPATResultIsInformationalAndDoesNotPublishInvalidToken() async {
        var invalidCount = 0
        let model = PassCLIPATSettingsModel(
            sessionMutationGate: PassCLISessionMutationGate(), credentialStore: OwnershipCredentials(),
            loginWithSavedToken: { _ in .busy }, invalidPATHandler: { _ in invalidCount += 1 }
        )
        await model.refreshSavedTokenState()
        await model.loginUsingSavedToken()
        #expect(model.statusMessage == PassCLIPATLoginResult.busy.userFacingMessage)
        #expect(model.errorMessage == nil)
        #expect(model.hasSavedToken)
        #expect(!model.isLoggingIn)
        #expect(invalidCount == 0)
    }

    @Test
    func busyBrowserResultDoesNotClearOrPublishAuthenticationFailure() {
        let poster = BusyNotificationPoster()
        var cleared = 0
        var requested = 0
        let notifier = PassCLILoginNotifier(
            notificationRouter: nil, poster: poster, startLogin: {},
            showLoginRequired: { requested += 1 }, clearLoginRequired: { cleared += 1 }
        )
        notifier.handleLoginResult(.busy)
        #expect(poster.titles == [PassCLIPATLoginResult.busy.userFacingMessage])
        #expect(poster.categories == [nil])
        #expect(poster.loggedOutCount == 0)
        #expect(cleared == 0)
        #expect(requested == 0)
    }
}
