import Testing
@testable import Quick_Access_for_Pass

@MainActor
private final class FakeRecommendedVersionPoster: PassCLIUpdateNotificationPosting {
    var messages: [(title: String, body: String)] = []

    func postRecommendedVersionNotification(title: String, body: String) {
        messages.append((title, body))
    }
}

@MainActor
@Suite("Pass CLI recommended version notifier")
struct PassCLIRecommendedVersionNotifierTests {
    @Test("posts startup warning only once")
    func postsStartupWarningOnlyOnce() {
        let poster = FakeRecommendedVersionPoster()
        let notifier = PassCLIRecommendedVersionNotifier(poster: poster)
        let warning = PassCLIRecommendedVersionWarning(
            activeVersion: PassCLIVersion(major: 2, minor: 1, patch: 4),
            recommendedVersion: PassCLIVersion(major: 2, minor: 2, patch: 1)
        )

        notifier.postStartupWarningIfNeeded(warning)
        notifier.postStartupWarningIfNeeded(warning)

        #expect(poster.messages.count == 1)
        #expect(poster.messages.first?.body.contains("2.2.1") == true)
        #expect(poster.messages.first?.body.contains("GitHub issue") == true)
    }

    @Test("does not post when there is no warning")
    func doesNotPostWithoutWarning() {
        let poster = FakeRecommendedVersionPoster()
        let notifier = PassCLIRecommendedVersionNotifier(poster: poster)

        notifier.postStartupWarningIfNeeded(nil)

        #expect(poster.messages.isEmpty)
    }
}
