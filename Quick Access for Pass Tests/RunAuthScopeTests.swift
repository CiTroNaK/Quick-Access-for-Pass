import Testing
import Foundation
@testable import Quick_Access_for_Pass

@MainActor
@Suite("scopeOptions Tests")
struct ScopeOptionsTests {
    @Test("exact identities are stable and use the complete independently calculated digest", arguments: [
        (["gh", "--version"], "542e3297bd773eb85837c9153b1a828f55c98f274d6d4ad6f9a89397e70625ad"),
        (["cmd", "é"], "e31ad66a13be04b9768f84e443eede7374c46639535dba653583ca808726d9f8"),
        (["cmd", "e\u{0301}"], "f6afe58b052f0971ddd19a9d03008fd6338d978b8f9d7ea5da2d0652ef725aba"),
        (["cmd", ""], "59f01badde9739796037e9cda7403f5345067c43165253fb71c532b55dc04435"),
        (["/usr/bin/gh", "--version"], "aa00ad172e6e10ad3716ac765061aa5ba6cc0cdb30cae06b15bcca9f84bb52f7")
    ])
    func fixedExactDigests(command: [String], digest: String) throws {
        // Fixtures calculated independently with Python hashlib and struct.pack(">Q", ...).
        let scope = try #require(RunAuthorizationScope.exact(command: command))
        #expect(scope.identity.matchValue == digest)
        #expect(scope.identity.matchType == .exactArgumentsV1)
        #expect(scope.isExact)
        #expect(RunAuthorizationScope.exact(command: command)?.identity == scope.identity)
    }

    @Test("exact framing preserves literal argument boundaries and bytes", arguments: [
        (["cmd", "a b"], ["cmd", "a", "b"]),
        (["cmd", "a", "b"], ["cmd", "b", "a"]),
        (["cmd", "a"], ["cmd", "b"]),
        (["cmd", "a"], ["cmd"]),
        (["cmd", "a"], ["cmd", "a", "b"]),
        (["cmd", ""], ["cmd"]),
        (["cmd", "", "a"], ["cmd", "a", ""]),
        (["cmd", " a "], ["cmd", "a"]),
        (["cmd", "a\tb"], ["cmd", "a b"]),
        (["cmd", "é"], ["cmd", "e\u{0301}"]),
        (["/usr/bin/cmd", "a"], ["cmd", "a"]),
        (["CMD", "a"], ["cmd", "a"])
    ])
    func literalVectorsDiffer(first: [String], second: [String]) throws {
        let firstScope = try #require(RunAuthorizationScope.exact(command: first))
        let secondScope = try #require(RunAuthorizationScope.exact(command: second))
        #expect(firstScope.identity != secondScope.identity)
    }

    @Test("exact labels use natural words and retain argument boundaries")
    func boundaryPreservingLabels() throws {
        #expect(RunAuthorizationScope.exact(command: ["gh", "--version"])?.label == "gh --version")
        #expect(RunAuthorizationScope.exact(command: ["tool", "a b"])?.label == "tool \"a b\"")
        #expect(RunAuthorizationScope.exact(command: ["tool", "a", "b"])?.label == "tool a b")
        #expect(RunAuthorizationScope.exact(command: ["tool", ""])?.label == "tool \"\"")
        let grouped = try #require(RunAuthorizationScope.exact(command: ["cmd", "a b"]))
        let separate = try #require(RunAuthorizationScope.exact(command: ["cmd", "a", "b"]))
        #expect(grouped.label != separate.label)
        #expect(RunAuthorizationScope.exact(command: ["cmd", "a\nb"])?.label != RunAuthorizationScope.exact(command: ["cmd", "a\\nb"])?.label)
        let sentinel = "DISTINCTIVE_CREDENTIAL_SENTINEL_987654"
        let scope = try #require(RunAuthorizationScope.exact(command: ["cmd", sentinel]))
        #expect(!scope.identity.matchValue.contains(sentinel))
    }

    @Test("exact rejects only empty vectors and empty executables")
    func invalidExactVectors() {
        #expect(RunAuthorizationScope.exact(command: []) == nil)
        #expect(RunAuthorizationScope.exact(command: ["", "arg"]) == nil)
        #expect(RunAuthorizationScope.exact(command: [" ", ""]) != nil)
        #expect(RunAuthWindowController.authorizationScopes(from: []).isEmpty)
        #expect(RunAuthWindowController.authorizationScopes(from: ["", "arg"]).isEmpty)
    }

    @Test("authorization scopes offer exact first and unchanged explicit prefixes")
    func exactBeforePrefixes() throws {
        let command = ["gh", "pr", "list", "--limit", "5"]
        let scopes = RunAuthWindowController.authorizationScopes(from: command)
        let exact = try #require(RunAuthorizationScope.exact(command: command))
        #expect(scopes.map(\.identity) == [exact.identity, RunAuthorizationIdentity(prefix: "gh pr list"), RunAuthorizationIdentity(prefix: "gh pr")])
        #expect(scopes.first == exact)
        #expect(scopes.dropFirst().allSatisfy { !$0.isExact && $0.identity.matchValue == $0.label })
        #expect(RunAuthorizationScope.prefix("gh pr").identity.matchValue == "gh pr")
        #expect(RunAuthorizationScope.prefix("gh pr").label == "gh pr")
        #expect(!RunAuthorizationScope.prefix("gh pr").isExact)
        #expect(RunAuthWindowController.authorizationScopes(from: ["gh", "--version"]).count == 1)
        #expect(RunAuthWindowController.authorizationScopes(from: ["/usr/bin/gh", "status"]).count == 1)
        #expect(RunAuthWindowController.authorizationScopes(from: ["gh"]).map(\.identity) == [
            try #require(RunAuthorizationScope.exact(command: ["gh"])).identity, RunAuthorizationIdentity(prefix: "gh")
        ])
    }

    @Test("prompt distinguishes exact argv from broader prefixes and includes full option text")
    func exactPromptLabelsAreNotIdentity() throws {
        let scopes = RunAuthWindowController.authorizationScopes(from: ["gh", "pr", "list", "--limit", "5"])
        let exact = try #require(scopes.first)
        #expect(exact.optionLabel.hasPrefix("Exact command: "))
        #expect(!exact.optionLabel.contains(String(exact.identity.matchValue.prefix(12))))
        #expect(exact.optionLabel.contains("--limit 5"))
        #expect(scopes[1].optionLabel == "Broader scope: gh pr list")
        #expect(scopes[2].optionLabel == "Broader scope: gh pr")
        #expect(scopes.map(\.identity).count == Set(scopes.map(\.identity)).count)
    }

    @Test("bare command → single-token scope")
    func bareCommand() {
        let options = RunAuthWindowController.scopeOptions(from: ["gh"])
        #expect(options == ["gh"])
    }

    @Test("2-token extraction → single 2-token scope")
    func twoTokenCommand() {
        let options = RunAuthWindowController.scopeOptions(from: ["gh", "status", "--json"])
        #expect(options == ["gh status"])
    }

    @Test("3-token extraction → narrow → wide, floored at 2")
    func threeTokenCommand() {
        let options = RunAuthWindowController.scopeOptions(from: ["gh", "pr", "list", "--limit", "5"])
        #expect(options == ["gh pr list", "gh pr"])
    }

    @Test("gh api URL extracts to 2 tokens, single scope")
    func ghApiURL() {
        let options = RunAuthWindowController.scopeOptions(
            from: ["gh", "api", "repos/:owner/:repo/actions/runs/24529102039/jobs", "--jq"]
        )
        #expect(options == ["gh api"])
    }

    @Test("multi-token input yielding only 1 identifier token → empty (no safe scope)")
    func oneIdentifierFromMulti() {
        let options = RunAuthWindowController.scopeOptions(from: ["python3", "script.py"])
        #expect(options == [])
    }

    @Test("empty input → empty")
    func emptyInput() {
        let options = RunAuthWindowController.scopeOptions(from: [])
        #expect(options == [])
    }

    @Test("path-prefixed binary → empty")
    func pathPrefixedBinary() {
        let options = RunAuthWindowController.scopeOptions(from: ["/usr/bin/gh", "status"])
        #expect(options == [])
    }

    @Test("first token is a flag → empty")
    func leadingFlag() {
        let options = RunAuthWindowController.scopeOptions(from: ["--help"])
        #expect(options == [])
    }

    @Test("narrow → wide order is preserved")
    func orderNarrowToWide() {
        let options = RunAuthWindowController.scopeOptions(from: ["aws", "s3", "cp"])
        #expect(options == ["aws s3 cp", "aws s3"])
    }
}

// MARK: - Narrow-before-wide matching

@MainActor
@Suite("Scope Matching Tests")
struct ScopeMatchingTests {
    func makeTestDB() throws -> DatabaseManager {
        try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
    }

    @Test("exact remembered approvals and denials match only the complete vector", arguments: [false, true])
    func exactDecisionDoesNotWiden(allowed: Bool) throws {
        let db = try makeTestDB()
        let command = ["gh", "pr", "list", "--limit", "5"]
        let exact = try #require(RunAuthorizationScope.exact(command: command))
        try db.saveRunDecision(
            appIdentifier: "com.test.app", scope: exact, profileSlug: "gh",
            expiresAt: nil, allowed: allowed
        )
        let controller = RunAuthWindowController(
            databaseManager: db, keychainService: FakeBiometricAuthorizer(outcome: .success(())), callbacks: .noop
        )
        let match = try #require(controller.anyCachedMatch(
            appIdentifier: "com.test.app", profileSlug: "gh",
            scopeOptions: RunAuthWindowController.authorizationScopes(from: command).map(\.identity)
        ))
        #expect(match.identity == exact.identity)
        #expect(match.allowed == allowed)
        for changed in [
            ["gh", "pr", "list", "--limit", "6"], ["gh", "pr", "list", "--limit"],
            command + ["--json"], ["gh", "pr", "list", "5", "--limit"]
        ] {
            #expect(controller.anyCachedMatch(
                appIdentifier: "com.test.app", profileSlug: "gh",
                scopeOptions: RunAuthWindowController.authorizationScopes(from: changed).map(\.identity)
            ) == nil)
        }
        #expect(controller.anyCachedMatch(appIdentifier: "other", profileSlug: "gh", scopeOptions: [exact.identity]) == nil)
        #expect(controller.anyCachedMatch(appIdentifier: "com.test.app", profileSlug: "other", scopeOptions: [exact.identity]) == nil)
    }

    @Test("exact persistent decisions beat opposite broader session decisions", arguments: [false, true])
    func exactPersistentPrecedence(allowed: Bool) throws {
        let db = try makeTestDB()
        let command = ["gh", "pr", "list", "--limit", "5"]
        let exact = try #require(RunAuthorizationScope.exact(command: command))
        try db.saveRunDecision(
            appIdentifier: "com.test.app", scope: exact, profileSlug: "gh", expiresAt: nil, allowed: allowed
        )
        let controller = RunAuthWindowController(
            databaseManager: db, keychainService: FakeBiometricAuthorizer(outcome: .success(())), callbacks: .noop
        )
        controller.storeSessionCache(appIdentifier: "com.test.app", profileSlug: "gh", scope: RunAuthorizationIdentity(prefix: "gh pr list"), allowed: !allowed)
        let match = try #require(controller.anyCachedMatch(
            appIdentifier: "com.test.app", profileSlug: "gh",
            scopeOptions: RunAuthWindowController.authorizationScopes(from: command).map(\.identity)
        ))
        #expect(match.identity == exact.identity)
        #expect(match.allowed == allowed)
        controller.storeSessionCache(appIdentifier: "com.test.app", profileSlug: "gh", scope: exact.identity, allowed: !allowed)
        #expect(controller.anyCachedMatch(
            appIdentifier: "com.test.app", profileSlug: "gh",
            scopeOptions: RunAuthWindowController.authorizationScopes(from: command).map(\.identity)
        )?.allowed == !allowed)
    }

    @Test("exact session approvals stay within the same argv, app and profile")
    func exactSessionApprovalIsolation() throws {
        let controller = RunAuthWindowController(
            databaseManager: try makeTestDB(),
            keychainService: FakeBiometricAuthorizer(outcome: .success(())), callbacks: .noop
        )
        let exact = try #require(RunAuthorizationScope.exact(command: ["gh", "--version"]))
        controller.storeSessionCache(appIdentifier: "app", profileSlug: "work", scope: exact.identity, allowed: true)
        #expect(controller.anyCachedMatch(appIdentifier: "app", profileSlug: "work", scopeOptions: [exact.identity])?.allowed == true)
        #expect(controller.anyCachedMatch(appIdentifier: "other", profileSlug: "work", scopeOptions: [exact.identity]) == nil)
        #expect(controller.anyCachedMatch(appIdentifier: "app", profileSlug: "other", scopeOptions: [exact.identity]) == nil)
        #expect(controller.anyCachedMatch(appIdentifier: "app", profileSlug: "work", scopeOptions:
            RunAuthWindowController.authorizationScopes(from: ["gh", "--version", "--other"]).map(\.identity)) == nil)
    }

    @Test("wider decision matches narrower command")
    func widerMatchesNarrower() throws {
        let db = try makeTestDB()
        try db.saveRunDecision(
            appIdentifier: "com.test.app",
            scope: RunAuthorizationScope.prefix("gh pr"),
            profileSlug: "gh",
            expiresAt: Date().addingTimeInterval(3600), allowed: true
        )
        let options = RunAuthWindowController.scopeOptions(
            from: ["gh", "pr", "list", "--limit", "5"]
        )
        // Simulate cachedScopeMatch's iteration
        var match: String?
        for scope in options {
            if (try? db.findValidRunDecision(
                appIdentifier: "com.test.app",
                identity: RunAuthorizationIdentity(prefix: scope),
                profileSlug: "gh"
            )) != nil {
                match = scope
                break
            }
        }
        #expect(match == "gh pr")
    }

    @Test("persisted denial retains its decision")
    func persistedDenialRetainsDecision() throws {
        let db = try makeTestDB()
        try db.saveRunDecision(
            appIdentifier: "com.test.app",
            scope: RunAuthorizationScope.prefix("gh pr"),
            profileSlug: "gh",
            expiresAt: Date().addingTimeInterval(3600),
            allowed: false
        )
        let controller = RunAuthWindowController(
            databaseManager: db,
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
            callbacks: .noop
        )

        let match = try #require(controller.anyCachedMatch(
            appIdentifier: "com.test.app",
            profileSlug: "gh",
            scopeOptions: ["gh pr list", "gh pr"].map(RunAuthorizationIdentity.init(prefix:))
        ))
        #expect(match.identity.matchValue == "gh pr")
        #expect(match.allowed == false)
    }

    @Test("narrow persisted decisions beat wider session decisions", arguments: [false, true])
    func narrowPersistedDecisionWins(allowed: Bool) throws {
        let db = try makeTestDB()
        try db.saveRunDecision(
            appIdentifier: "com.test.app",
            scope: RunAuthorizationScope.prefix("gh pr list"),
            profileSlug: "gh",
            expiresAt: nil,
            allowed: allowed
        )
        let controller = RunAuthWindowController(
            databaseManager: db,
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
            callbacks: .noop
        )
        controller.storeSessionCache(
            appIdentifier: "com.test.app", profileSlug: "gh", scope: RunAuthorizationIdentity(prefix: "gh pr"), allowed: allowed == false
        )

        let match = try #require(controller.anyCachedMatch(
            appIdentifier: "com.test.app", profileSlug: "gh", scopeOptions: ["gh pr list", "gh pr"].map(RunAuthorizationIdentity.init(prefix:))
        ))
        #expect(match.identity.matchValue == "gh pr list")
        #expect(match.allowed == allowed)
    }

    @Test("session decisions retain precedence within the same scope", arguments: [false, true])
    func sameScopeSessionDecisionWins(allowed: Bool) throws {
        let db = try makeTestDB()
        try db.saveRunDecision(
            appIdentifier: "com.test.app", scope: RunAuthorizationScope.prefix("gh pr"), profileSlug: "gh",
            expiresAt: nil, allowed: allowed == false
        )
        let controller = RunAuthWindowController(
            databaseManager: db,
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
            callbacks: .noop
        )
        controller.storeSessionCache(
            appIdentifier: "com.test.app", profileSlug: "gh", scope: RunAuthorizationIdentity(prefix: "gh pr"), allowed: allowed
        )

        let match = try #require(controller.anyCachedMatch(
            appIdentifier: "com.test.app", profileSlug: "gh", scopeOptions: ["gh pr list", "gh pr"].map(RunAuthorizationIdentity.init(prefix:))
        ))
        #expect(match.identity.matchValue == "gh pr")
        #expect(match.allowed == allowed)
    }

    @Test("expired session approval falls back to persisted denial")
    func expiredSessionApprovalFallsBackToDenial() throws {
        let db = try makeTestDB()
        try db.saveRunDecision(
            appIdentifier: "com.test.app", scope: RunAuthorizationScope.prefix("gh pr"), profileSlug: "gh",
            expiresAt: nil, allowed: false
        )
        let controller = RunAuthWindowController(
            databaseManager: db,
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
            callbacks: .noop
        )
        controller.storeSessionCache(
            appIdentifier: "com.test.app", profileSlug: "gh", scope: RunAuthorizationIdentity(prefix: "gh pr"), allowed: true
        )
        for key in controller.sessionCache.keys {
            controller.sessionCache[key]?.expiresAt = .distantPast
        }

        let match = try #require(controller.anyCachedMatch(
            appIdentifier: "com.test.app", profileSlug: "gh", scopeOptions: [RunAuthorizationIdentity(prefix: "gh pr")]
        ))
        #expect(match.allowed == false)
    }

    @Test("session decisions cannot collide across app and profile boundaries")
    func sessionIdentityComponentsStaySeparate() throws {
        let controller = RunAuthWindowController(
            databaseManager: try makeTestDB(),
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
            callbacks: .noop
        )
        controller.storeSessionCache(
            appIdentifier: "app|profile", profileSlug: "profile", scope: RunAuthorizationIdentity(prefix: "gh pr"), allowed: true
        )

        #expect(controller.anyCachedMatch(
            appIdentifier: "app", profileSlug: "profile|profile", scopeOptions: [RunAuthorizationIdentity(prefix: "gh pr")]
        ) == nil)
        #expect(controller.anyCachedMatch(
            appIdentifier: "app|profile", profileSlug: "other", scopeOptions: [RunAuthorizationIdentity(prefix: "gh pr")]
        ) == nil)
        #expect(controller.anyCachedMatch(
            appIdentifier: "app|profile", profileSlug: "profile", scopeOptions: [RunAuthorizationIdentity(prefix: "gh issue")]
        ) == nil)
    }

    @Test("narrower decision wins when both exist")
    func narrowerWins() throws {
        let db = try makeTestDB()
        try db.saveRunDecision(
            appIdentifier: "com.test.app",
            scope: RunAuthorizationScope.prefix("gh pr list"),
            profileSlug: "gh",
            expiresAt: Date().addingTimeInterval(3600), allowed: true
        )
        try db.saveRunDecision(
            appIdentifier: "com.test.app",
            scope: RunAuthorizationScope.prefix("gh pr"),
            profileSlug: "gh",
            expiresAt: Date().addingTimeInterval(3600), allowed: true
        )
        let options = RunAuthWindowController.scopeOptions(
            from: ["gh", "pr", "list"]
        )
        var match: String?
        for scope in options {
            if (try? db.findValidRunDecision(
                appIdentifier: "com.test.app",
                identity: RunAuthorizationIdentity(prefix: scope),
                profileSlug: "gh"
            )) != nil {
                match = scope
                break
            }
        }
        #expect(match == "gh pr list")
    }

    @Test("no match when scope options are empty")
    func emptyOptionsNoMatch() throws {
        let db = try makeTestDB()
        try db.saveRunDecision(
            appIdentifier: "com.test.app",
            scope: RunAuthorizationScope.prefix("python3"),
            profileSlug: "py",
            expiresAt: Date().addingTimeInterval(3600), allowed: true
        )
        let options = RunAuthWindowController.scopeOptions(
            from: ["python3", "script.py"]
        )
        #expect(options.isEmpty)
        // Because options is empty, the controller would never look up a cached decision.
    }

    @Test("stale gh-api-with-URL rows no longer match new extraction")
    func staleURLRowDoesNotMatch() throws {
        let db = try makeTestDB()
        try db.saveRunDecision(
            appIdentifier: "com.test.app",
            scope: RunAuthorizationScope.prefix("gh api repos/:owner/:repo/actions/runs/24529102039/jobs"),
            profileSlug: "gh",
            expiresAt: Date().addingTimeInterval(3600), allowed: true
        )
        let options = RunAuthWindowController.scopeOptions(
            from: ["gh", "api", "repos/:owner/:repo/actions/runs/24529102039/jobs"]
        )
        #expect(options == ["gh api"])
        let match = try db.findValidRunDecision(
            appIdentifier: "com.test.app",
            identity: RunAuthorizationIdentity(prefix: "gh api"),
            profileSlug: "gh"
        )
        #expect(match == nil)
    }

    @Test("gh api decision matches calls with different URL arguments")
    func ghApiRemembersAcrossDifferentURLs() throws {
        let db = try makeTestDB()
        try db.saveRunDecision(
            appIdentifier: "com.test.app",
            scope: RunAuthorizationScope.prefix("gh api"),
            profileSlug: "gh",
            expiresAt: Date().addingTimeInterval(3600), allowed: true
        )
        let firstCall = ["gh", "api", "repos/:owner/:repo/actions/runs/24565147199/jobs", "--jq", ".jobs[]"]
        let secondCall = ["gh", "api", "repos/:owner/:repo/actions/runs/99999999/jobs", "--jq", ".jobs[]"]
        let firstOptions = RunAuthWindowController.scopeOptions(from: firstCall)
        let secondOptions = RunAuthWindowController.scopeOptions(from: secondCall)
        #expect(firstOptions == ["gh api"])
        #expect(secondOptions == ["gh api"])
        for scope in firstOptions {
            let match = try? db.findValidRunDecision(
                appIdentifier: "com.test.app",
                identity: RunAuthorizationIdentity(prefix: scope),
                profileSlug: "gh"
            )
            #expect(match != nil)
        }
        for scope in secondOptions {
            let match = try? db.findValidRunDecision(
                appIdentifier: "com.test.app",
                identity: RunAuthorizationIdentity(prefix: scope),
                profileSlug: "gh"
            )
            #expect(match != nil)
        }
    }
}
