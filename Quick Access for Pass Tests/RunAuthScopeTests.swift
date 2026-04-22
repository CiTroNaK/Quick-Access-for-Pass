import Testing
import Foundation
@testable import Quick_Access_for_Pass

@MainActor
@Suite("scopeOptions Tests")
struct ScopeOptionsTests {
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

    @Test("wider decision matches narrower command")
    func widerMatchesNarrower() throws {
        let db = try makeTestDB()
        try db.saveRunDecision(
            appIdentifier: "com.test.app",
            subcommand: "gh pr",
            profileSlug: "gh",
            expiresAt: Date().addingTimeInterval(3600)
        )
        let options = RunAuthWindowController.scopeOptions(
            from: ["gh", "pr", "list", "--limit", "5"]
        )
        // Simulate cachedScopeMatch's iteration
        var match: String?
        for scope in options {
            if (try? db.findValidRunDecision(
                appIdentifier: "com.test.app",
                subcommand: scope,
                profileSlug: "gh"
            )) != nil {
                match = scope
                break
            }
        }
        #expect(match == "gh pr")
    }

    @Test("narrower decision wins when both exist")
    func narrowerWins() throws {
        let db = try makeTestDB()
        try db.saveRunDecision(
            appIdentifier: "com.test.app",
            subcommand: "gh pr list",
            profileSlug: "gh",
            expiresAt: Date().addingTimeInterval(3600)
        )
        try db.saveRunDecision(
            appIdentifier: "com.test.app",
            subcommand: "gh pr",
            profileSlug: "gh",
            expiresAt: Date().addingTimeInterval(3600)
        )
        let options = RunAuthWindowController.scopeOptions(
            from: ["gh", "pr", "list"]
        )
        var match: String?
        for scope in options {
            if (try? db.findValidRunDecision(
                appIdentifier: "com.test.app",
                subcommand: scope,
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
            subcommand: "python3",
            profileSlug: "py",
            expiresAt: Date().addingTimeInterval(3600)
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
            subcommand: "gh api repos/:owner/:repo/actions/runs/24529102039/jobs",
            profileSlug: "gh",
            expiresAt: Date().addingTimeInterval(3600)
        )
        let options = RunAuthWindowController.scopeOptions(
            from: ["gh", "api", "repos/:owner/:repo/actions/runs/24529102039/jobs"]
        )
        #expect(options == ["gh api"])
        let match = try db.findValidRunDecision(
            appIdentifier: "com.test.app",
            subcommand: "gh api",
            profileSlug: "gh"
        )
        #expect(match == nil)
    }

    @Test("gh api decision matches calls with different URL arguments")
    func ghApiRemembersAcrossDifferentURLs() throws {
        let db = try makeTestDB()
        try db.saveRunDecision(
            appIdentifier: "com.test.app",
            subcommand: "gh api",
            profileSlug: "gh",
            expiresAt: Date().addingTimeInterval(3600)
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
                subcommand: scope,
                profileSlug: "gh"
            )
            #expect(match != nil)
        }
        for scope in secondOptions {
            let match = try? db.findValidRunDecision(
                appIdentifier: "com.test.app",
                subcommand: scope,
                profileSlug: "gh"
            )
            #expect(match != nil)
        }
    }
}
