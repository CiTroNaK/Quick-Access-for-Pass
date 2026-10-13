import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Run remembered decisions view")
struct RunAuthDecisionsViewTests {
    private func decision(
        id: Int64 = 1,
        type: String = RunAuthorizationMatchType.exactArgumentsV1.rawValue,
        value: String = String(repeating: "a", count: 64),
        text: String = "gh --version",
        allowed: Bool = true
    ) -> RunAuthDecision {
        RunAuthDecision(
            id: id, matchType: type, matchValue: value, commandText: text,
            appIdentifier: "com.example.Terminal", profileSlug: "work",
            expiresAt: .distantFuture, allowed: allowed, appTeamID: "TEAM"
        )
    }

    @Test func exactPresentationShowsFullCommandAndKnownType() {
        let presentation = RunAuthDecisionRowPresentation(decision: decision(), profileName: "Work")
        #expect(presentation.bundleID == "com.example.Terminal")
        #expect(presentation.primaryText == "gh --version")
        #expect(presentation.scopeHelpText == "gh --version")
        #expect(presentation.secondaryText(relativeExpiration: "Forever") == "Exact command · Allowed · Work · Forever")
    }

    @Test func prefixAndUnknownTypesAreVisibleAndOutcomesStayLocalized() {
        let prefix = RunAuthDecisionRowPresentation(
            decision: decision(type: RunAuthorizationMatchType.commandPrefixV1.rawValue, value: "gh pr", text: "gh pr", allowed: false),
            profileName: "Production"
        )
        #expect(prefix.primaryText == "gh pr")
        #expect(prefix.secondaryText(relativeExpiration: "in 1 hour") == "Command prefix · Denied · Production · in 1 hour")

        let unknown = RunAuthDecisionRowPresentation(
            decision: decision(type: "future-type", value: "future-value", text: "full future command"),
            profileName: "Work"
        )
        #expect(unknown.primaryText == "full future command")
        #expect(unknown.scopeHelpText == "full future command")
        #expect(unknown.secondaryText(relativeExpiration: "Forever").hasPrefix("Unknown matching type · Allowed"))
    }

    @Test(arguments: [false, true])
    @MainActor
    func exactRowsRetainDistinctTypedIdentitiesAndRemoveByID(allowed: Bool) throws {
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let firstScope = try #require(RunAuthorizationScope.exact(command: ["gh", "--version"]))
        let secondScope = try #require(RunAuthorizationScope.exact(command: ["gh", "--version", "--help"]))
        for scope in [firstScope, secondScope] {
            try db.saveRunDecision(appIdentifier: "app", scope: scope, profileSlug: "work", expiresAt: nil, allowed: allowed)
        }
        let rows = try db.allRunAuthDecisions()
        #expect(rows.count == 2)
        #expect(rows.map(\.id).count == Set(rows.map(\.id)).count)
        let presentations = rows.map { RunAuthDecisionRowPresentation(decision: $0, profileName: "Work") }
        #expect(presentations.map(\.primaryText).sorted() == ["gh --version", "gh --version --help"])
        #expect(presentations.allSatisfy { $0.secondaryText(relativeExpiration: "Forever").contains(allowed ? "Allowed" : "Denied") })
        try db.removeRunAuthDecision(id: rows[0].id)
        #expect(try db.allRunAuthDecisions().map(\.id) == [rows[1].id])
    }
}
