import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Run remembered decisions view")
struct RunAuthDecisionsViewTests {
    @Test func presentationUsesAppIdentifierForIconLookup() {
        let decision = RunAuthDecision(
            appIdentifier: "com.fournova.Tower",
            subcommand: "git fetch",
            profileSlug: "work",
            expiresAt: .distantFuture,
            appTeamID: nil
        )

        let presentation = RunAuthDecisionRowPresentation(
            decision: decision,
            profileName: "Work"
        )

        #expect(presentation.bundleID == "com.fournova.Tower")
        #expect(presentation.primaryText == "git fetch")
    }

    @Test func presentationFormatsSecondaryTextLikeSettingsRow() {
        let decision = RunAuthDecision(
            appIdentifier: "com.apple.Terminal",
            subcommand: "git pull",
            profileSlug: "prod",
            expiresAt: .distantFuture,
            appTeamID: nil
        )

        let presentation = RunAuthDecisionRowPresentation(
            decision: decision,
            profileName: "Production"
        )

        #expect(presentation.secondaryText(relativeExpiration: "in 1 hour") == "Production · in 1 hour")
    }
}
