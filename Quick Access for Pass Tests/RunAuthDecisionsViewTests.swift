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

        #expect(presentation.secondaryText(relativeExpiration: "in 1 hour") == "Allowed · Production · in 1 hour")
    }

    @Test func presentationLabelsDeniedDecision() {
        let decision = RunAuthDecision(
            appIdentifier: "com.apple.Terminal",
            subcommand: "git pull",
            profileSlug: "prod",
            expiresAt: .distantFuture,
            allowed: false,
            appTeamID: nil
        )

        let presentation = RunAuthDecisionRowPresentation(
            decision: decision,
            profileName: "Production"
        )

        #expect(presentation.secondaryText(relativeExpiration: "in 1 hour") == "Denied · Production · in 1 hour")
    }
    @Test(arguments: [false, true])
    @MainActor
    func exactRowsKeepFullIdentityAndOutcome(allowed: Bool) throws {
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let first = "exact-v1:" + String(repeating: "a", count: 64)
        let second = "exact-v1:" + String(repeating: "a", count: 63) + "b"
        for key in [first, second] {
            try db.saveRunDecision(appIdentifier: "app", subcommand: key, profileSlug: "work",
                                   expiresAt: nil, allowed: allowed)
        }
        let rows = try db.allRunAuthDecisions()
        #expect(rows.count == 2)
        #expect(rows[0].compositeKey != rows[1].compositeKey)
        let presentations = rows.map { RunAuthDecisionRowPresentation(decision: $0, profileName: "Work") }
        #expect(presentations[0].primaryText == "Exact command (aaaaaaaaaaaa)")
        #expect(presentations[0].primaryText == presentations[1].primaryText)
        for presentation in presentations {
            #expect(presentation.scopeHelpText == presentation.decision.subcommand)
            #expect(presentation.secondaryText(relativeExpiration: "Forever") ==
                    "\(allowed ? "Allowed" : "Denied") · Work · Forever")
        }
        try db.removeRunAuthDecision(appIdentifier: rows[0].appIdentifier,
                                     subcommand: rows[0].subcommand, profileSlug: rows[0].profileSlug)
        #expect(try db.allRunAuthDecisions().map(\.subcommand) == [rows[1].subcommand])
    }

    @Test(arguments: ["git fetch", "exact-v1:abc", "exact-v1:" + String(repeating: "A", count: 64),
                      "exact-v1:" + String(repeating: "a", count: 65),
                      "exact-v2:" + String(repeating: "a", count: 64),
                      "exact-v1:" + String(repeating: "a", count: 64) + "\n",
                      "exact-v1:" + String(repeating: "g", count: 64),
                      "exact-v1:" + String(repeating: "a", count: 63)])
    func prefixesAndMalformedKeysRemainLiteral(key: String) {
        #expect(RunAuthorizationScope.persistedLabel(for: key) == key)
    }
}
