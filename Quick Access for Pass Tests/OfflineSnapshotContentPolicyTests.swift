import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Offline snapshot content contracts")
nonisolated struct OfflineSnapshotContentPolicyTests {
    @Test(arguments: [
        EmailCase(email: nil, includeEmail: false, revision: 0),
        EmailCase(email: nil, includeEmail: true, revision: 0),
        EmailCase(email: "", includeEmail: true, revision: 0),
        EmailCase(email: " \t\n", includeEmail: true, revision: 0),
        EmailCase(email: "synthetic@example.test", includeEmail: true, revision: 1),
        EmailCase(email: " \nsynthetic@example.test\t", includeEmail: true, revision: 1)
    ])
    func actualAliasContentCertifiesItsRevision(_ testCase: EmailCase) throws {
        let item = try offlineTestAliasItem(email: testCase.email, includeEmail: testCase.includeEmail)
        #expect(OfflineSnapshotContentPolicy.current.satisfiedRevision(for: item) == testCase.revision)
    }

    @Test func otherTypesHaveNoCurrentUpgradeRequirement() throws {
        let types: [ItemType] = [.login, .creditCard, .note, .identity, .sshKey, .wifi, .custom]
        for type in types {
            #expect(OfflineSnapshotContentPolicy.current.needsRefresh(contentRevision: 0, for: type) == false)
            #expect(OfflineSnapshotContentPolicy.current.requiredRevision(for: type) == 0)
        }
        let login = try offlineTestCLIItem(id: "item", vaultID: "vault", shareID: "share", password: "synthetic")
        var raw = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(login)) as? [String: Any])
        raw["alias_email"] = "synthetic@example.test"
        let incidentalEmail = try JSONDecoder().decode(CLIItem.self, from: JSONSerialization.data(withJSONObject: raw))
        #expect(OfflineSnapshotContentPolicy.current.satisfiedRevision(for: incidentalEmail) == 0)
    }

    @Test(arguments: [
        CumulativeCase(first: false, second: false, revision: 0),
        CumulativeCase(first: false, second: true, revision: 0),
        CumulativeCase(first: true, second: false, revision: 1),
        CumulativeCase(first: true, second: true, revision: 2)
    ])
    func revisionsCannotSkipAnEarlierContract(_ testCase: CumulativeCase) throws {
        let policy = OfflineSnapshotContentPolicy(requirements: [
            .alias: [{ _ in testCase.first }, { _ in testCase.second }]
        ])
        #expect(policy.satisfiedRevision(for: try offlineTestAliasItem(email: nil)) == testCase.revision)
    }

    @Test(arguments: [
        ComparisonCase(stored: 0, required: 0, refresh: false),
        ComparisonCase(stored: 0, required: 1, refresh: true),
        ComparisonCase(stored: 1, required: 1, refresh: false),
        ComparisonCase(stored: 0, required: 2, refresh: true),
        ComparisonCase(stored: 1, required: 2, refresh: true),
        ComparisonCase(stored: 2, required: 2, refresh: false),
        ComparisonCase(stored: 3, required: 2, refresh: false)
    ])
    func comparisonSupportsFutureRequirements(_ testCase: ComparisonCase) {
        let satisfied: OfflineSnapshotContentPolicy.Requirement = { _ in true }
        let policy = OfflineSnapshotContentPolicy(requirements: [
            .alias: Array(repeating: satisfied, count: testCase.required)
        ])
        #expect(policy.needsRefresh(contentRevision: testCase.stored, for: .alias) == testCase.refresh)
    }

    @Test func itemTypeContractsAdvanceIndependently() {
        let satisfied: OfflineSnapshotContentPolicy.Requirement = { _ in true }
        let policy = OfflineSnapshotContentPolicy(requirements: [.alias: [satisfied], .login: [satisfied, satisfied]])
        #expect(policy.needsRefresh(contentRevision: 1, for: .alias) == false)
        #expect(policy.needsRefresh(contentRevision: 1, for: .login))
        #expect(policy.needsRefresh(contentRevision: 0, for: .note) == false)
    }

    struct EmailCase: Sendable {
        let email: String?
        let includeEmail: Bool
        let revision: Int
    }
    struct CumulativeCase: Sendable {
        let first: Bool
        let second: Bool
        let revision: Int
    }
    struct ComparisonCase: Sendable {
        let stored: Int
        let required: Int
        let refresh: Bool
    }
}
