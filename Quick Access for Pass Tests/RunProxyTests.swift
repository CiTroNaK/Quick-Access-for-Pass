import Testing
import Foundation
import Darwin
import GRDB
@testable import Quick_Access_for_Pass

// MARK: - Run Profile & Env Mapping CRUD

@Suite("RunProfile Tests")
struct RunProfileTests {
    func makeTestDB() throws -> DatabaseManager {
        try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
    }

    @Test("saves and retrieves a profile")
    func profileCRUD() throws {
        let db = try makeTestDB()
        let profile = RunProfile(id: nil, name: "GitHub CLI", slug: "github-cli", cacheDuration: "5 minutes", createdAt: Date())
        let saved = try db.saveRunProfile(profile, mappings: [])
        #expect(saved.id != nil)

        let found = try db.findRunProfile(slug: "github-cli")
        #expect(found != nil)
        #expect(found?.name == "GitHub CLI")
    }

    @Test("lists all profiles sorted by name")
    func allProfilesSorted() throws {
        let db = try makeTestDB()
        let a = RunProfile(id: nil, name: "Zebra", slug: "zebra", cacheDuration: "5 minutes", createdAt: Date())
        let b = RunProfile(id: nil, name: "Alpha", slug: "alpha", cacheDuration: "5 minutes", createdAt: Date())
        _ = try db.saveRunProfile(a, mappings: [])
        _ = try db.saveRunProfile(b, mappings: [])

        let all = try db.allRunProfiles()
        #expect(all.count == 2)
        #expect(all[0].name == "Alpha")
        #expect(all[1].name == "Zebra")
    }

    @Test("deletes a profile and cascades to mappings")
    func deleteProfile() throws {
        let db = try makeTestDB()
        let profile = RunProfile(id: nil, name: "Test", slug: "test", cacheDuration: "5 minutes", createdAt: Date())
        let mapping = RunProfileEnvMapping(id: nil, profileId: 0, envVariable: "TOKEN", secretReference: "pass://v/i/f")
        let saved = try db.saveRunProfile(profile, mappings: [mapping])

        try db.deleteRunProfile(id: saved.id!)
        #expect(try db.findRunProfile(slug: "test") == nil)
        #expect(try db.envMappings(forProfileId: saved.id!).isEmpty)
    }

    @Test("saves and retrieves env mappings")
    func envMappings() throws {
        let db = try makeTestDB()
        let profile = RunProfile(id: nil, name: "Test", slug: "test", cacheDuration: "5 minutes", createdAt: Date())
        let mappings = [
            RunProfileEnvMapping(id: nil, profileId: 0, envVariable: "GH_TOKEN", secretReference: "pass://Personal/GitHub/password"),
            RunProfileEnvMapping(id: nil, profileId: 0, envVariable: "AWS_KEY", secretReference: "pass://Work/AWS/key"),
        ]
        let saved = try db.saveRunProfile(profile, mappings: mappings)

        let retrieved = try db.envMappings(forProfileId: saved.id!)
        #expect(retrieved.count == 2)
        #expect(retrieved.contains { $0.envVariable == "GH_TOKEN" })
        #expect(retrieved.contains { $0.envVariable == "AWS_KEY" })
    }

    @Test("updating profile replaces mappings")
    func updateReplacesMapping() throws {
        let db = try makeTestDB()
        let profile = RunProfile(id: nil, name: "Test", slug: "test", cacheDuration: "5 minutes", createdAt: Date())
        let saved = try db.saveRunProfile(profile, mappings: [
            RunProfileEnvMapping(id: nil, profileId: 0, envVariable: "OLD", secretReference: "pass://v/i/f"),
        ])

        let updated = RunProfile(id: saved.id, name: "Test", slug: "test", cacheDuration: "1 hour", createdAt: saved.createdAt)
        _ = try db.saveRunProfile(updated, mappings: [
            RunProfileEnvMapping(id: nil, profileId: 0, envVariable: "NEW", secretReference: "pass://v/i/f"),
        ])

        let mappings = try db.envMappings(forProfileId: saved.id!)
        #expect(mappings.count == 1)
        #expect(mappings[0].envVariable == "NEW")

        let reloaded = try db.findRunProfile(slug: "test")
        #expect(reloaded?.cacheDuration == "1 hour")
    }

    @Test("slug uniqueness enforced")
    func slugUnique() throws {
        let db = try makeTestDB()
        let a = RunProfile(id: nil, name: "First", slug: "same", cacheDuration: "5 minutes", createdAt: Date())
        _ = try db.saveRunProfile(a, mappings: [])

        // Second profile with same slug should fail or replace
        let b = RunProfile(id: nil, name: "Second", slug: "same", cacheDuration: "5 minutes", createdAt: Date())
        // insert should fail due to unique constraint (slug is unique, id is different)
        #expect(throws: (any Error).self) {
            _ = try db.saveRunProfile(b, mappings: [])
        }
    }

    @Test("findRunProfile returns nil for unknown slug")
    func findUnknown() throws {
        let db = try makeTestDB()
        #expect(try db.findRunProfile(slug: "nonexistent") == nil)
    }

    @Test("saveRunProfile rejects reserved ping slug")
    func saveRunProfileRejectsReservedSlug() throws {
        let db = try makeTestDB()
        let profile = RunProfile(
            id: nil,
            name: "Malicious",
            slug: RunProxyProbeConstants.reservedPingSlug,
            cacheDuration: "5 minutes",
            createdAt: Date()
        )
        #expect(throws: RunProfileError.reservedSlug) {
            _ = try db.saveRunProfile(profile, mappings: [])
        }
    }
}

// MARK: - Run Auth Decision CRUD

@Suite("RunAuthDecision Tests")
struct RunAuthDecisionTests {
    func makeTestDB() throws -> DatabaseManager {
        try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
    }

    private func scope(_ value: String) -> RunAuthorizationScope { .prefix(value) }
    private func identity(_ value: String) -> RunAuthorizationIdentity { RunAuthorizationIdentity(prefix: value) }

    @Test("typed decisions preserve identity, boundaries, expiration and outcome")
    func typedCRUD() throws {
        let db = try makeTestDB()
        let prefix = scope("gh pr list")
        let expiry = Date().addingTimeInterval(300)
        try db.saveRunDecision(appIdentifier: "com.test", scope: prefix, profileSlug: "github-cli", expiresAt: expiry, allowed: true)
        let foundValue = try db.findValidRunDecision(appIdentifier: "com.test", identity: identity("gh pr list"), profileSlug: "github-cli")
        let found = try #require(foundValue)
        #expect(found.matchType == RunAuthorizationMatchType.commandPrefixV1.rawValue)
        #expect(found.matchValue == "gh pr list")
        #expect(found.commandText == "gh pr list")
        #expect(found.allowed)
        let id = found.id
        let newExpiry = Date().addingTimeInterval(3600)
        try db.saveRunDecision(appIdentifier: "com.test", scope: prefix, profileSlug: "github-cli", expiresAt: newExpiry, allowed: false)
        let updatedValue = try db.findValidRunDecision(appIdentifier: "com.test", identity: identity("gh pr list"), profileSlug: "github-cli")
        let updated = try #require(updatedValue)
        #expect(updated.id == id)
        #expect(updated.allowed == false)
        #expect(abs((updated.expiresAt?.timeIntervalSince(newExpiry) ?? .infinity)) < 1)
        #expect(try db.findValidRunDecision(appIdentifier: "com.test", identity: identity("gh pr create"), profileSlug: "github-cli") == nil)
        #expect(try db.findValidRunDecision(appIdentifier: "com.test", identity: identity("gh pr list"), profileSlug: "other-profile") == nil)
    }

    @Test("expired decisions are not returned and cleanup removes them")
    func cleanup() throws {
        let db = try makeTestDB()
        try db.saveRunDecision(appIdentifier: "app1", scope: scope("cmd1"), profileSlug: "p1", expiresAt: Date().addingTimeInterval(-100), allowed: true)
        try db.saveRunDecision(appIdentifier: "app2", scope: scope("cmd2"), profileSlug: "p2", expiresAt: Date().addingTimeInterval(300), allowed: false)
        #expect(try db.findValidRunDecision(appIdentifier: "app1", identity: identity("cmd1"), profileSlug: "p1") == nil)
        try db.cleanupExpiredRunDecisions()
        #expect(try db.allRunAuthDecisions().map(\.appIdentifier) == ["app2"])
    }

    @Test("removal selects only the given ID and stale IDs cannot remove a later row")
    func remove() throws {
        let db = try makeTestDB()
        try db.saveRunDecision(appIdentifier: "app1", scope: scope("cmd1"), profileSlug: "p1", expiresAt: Date().addingTimeInterval(300), allowed: true)
        try db.saveRunDecision(appIdentifier: "app2", scope: scope("cmd2"), profileSlug: "p2", expiresAt: Date().addingTimeInterval(300), allowed: true)
        let first = try #require(db.allRunAuthDecisions().first)
        try db.removeRunAuthDecision(id: first.id)
        #expect(try db.allRunAuthDecisions().map(\.appIdentifier) == ["app2"])

        try db.removeRunAuthDecision(id: try #require(db.allRunAuthDecisions().first?.id))
        try db.saveRunDecision(appIdentifier: "app3", scope: scope("cmd3"), profileSlug: "p3", expiresAt: nil, allowed: false)
        let replacement = try #require(db.allRunAuthDecisions().first)
        #expect(replacement.id > first.id)
        try db.removeRunAuthDecision(id: first.id)
        #expect(try db.allRunAuthDecisions().map(\.appIdentifier) == ["app3"])
    }

    @Test("identity matching is independent of editable display text and unknown rows remain readable")
    func displayTextDoesNotParticipateInMatching() throws {
        let db = try makeTestDB()
        let rule = scope("gh pr")
        try db.saveRunDecision(appIdentifier: "app", scope: rule, profileSlug: "p", expiresAt: nil, allowed: true)
        try db.writer.write { try $0.execute(sql: "UPDATE runAuthDecisions SET commandText = 'edited display label' WHERE appIdentifier = 'app'") }
        let foundValue = try db.findValidRunDecision(appIdentifier: "app", identity: rule.identity, profileSlug: "p")
        let found = try #require(foundValue)
        #expect(found.commandText == "edited display label")

        try db.writer.write {
            try $0.execute(
                sql: """
                    INSERT INTO runAuthDecisions
                        (matchType, matchValue, commandText, appIdentifier, profileSlug, allowed)
                    VALUES ('future-v9', 'future-value', 'edited display label', 'future-app', 'p', 1)
                    """
            )
        }
        let unknownValue = try db.allRunAuthDecisions().first { $0.matchType == "future-v9" }
        let unknown = try #require(unknownValue)
        #expect(unknown.commandText == "edited display label")
        let firstPresentation = RunAuthDecisionRowPresentation(decision: found, profileName: "Profile")
        let secondPresentation = RunAuthDecisionRowPresentation(decision: unknown, profileName: "Profile")
        #expect(firstPresentation.primaryText == secondPresentation.primaryText)
        #expect(found.matchType != unknown.matchType)
        #expect(found.matchValue != unknown.matchValue)
        #expect(found.id != unknown.id)
        let unknownMatch = try db.findValidRunDecision(appIdentifier: "future-app", identity: identity("future-value"), profileSlug: "p")
        #expect(unknownMatch == nil)
        try db.removeRunAuthDecision(id: unknown.id)
        #expect(try db.allRunAuthDecisions().contains { $0.appIdentifier == "future-app" } == false)
    }
}

// MARK: - Subcommand Extraction

@MainActor
@Suite("Subcommand Extraction Tests")
struct SubcommandExtractionTests {
    @Test("extracts up to 3 identifier tokens")
    func threeTokens() {
        let result = RunAuthWindowController.extractSubcommand(from: ["gh", "pr", "create", "--title", "Fix bug"])
        #expect(result == "gh pr create")
    }

    @Test("stops at first flag")
    func stopsAtFlag() {
        let result = RunAuthWindowController.extractSubcommand(from: ["gh", "--verbose", "pr", "list"])
        #expect(result == "gh")
    }

    @Test("stops at non-identifier token (URL/path/id)")
    func stopsAtNonIdentifier() {
        let result = RunAuthWindowController.extractSubcommand(from: ["gh", "api", "/repos/owner/repo", "extra"])
        #expect(result == "gh api")
    }

    @Test("stops at numeric id")
    func stopsAtNumericId() {
        let result = RunAuthWindowController.extractSubcommand(from: ["gh", "issue", "123"])
        #expect(result == "gh issue")
    }

    @Test("single bare identifier")
    func singleToken() {
        let result = RunAuthWindowController.extractSubcommand(from: ["gh"])
        #expect(result == "gh")
    }

    @Test("empty command")
    func emptyCommand() {
        let result = RunAuthWindowController.extractSubcommand(from: [])
        #expect(result == "")
    }

    @Test("all flags")
    func allFlags() {
        let result = RunAuthWindowController.extractSubcommand(from: ["--help", "--version"])
        #expect(result == "")
    }

    @Test("two tokens before flag")
    func twoTokens() {
        let result = RunAuthWindowController.extractSubcommand(from: ["gh", "pr", "--state=open"])
        #expect(result == "gh pr")
    }

    @Test("path-prefixed binary yields empty")
    func pathPrefixedBinary() {
        let result = RunAuthWindowController.extractSubcommand(from: ["/usr/bin/gh", "status"])
        #expect(result == "")
    }
}

// MARK: - Wire Protocol

@Suite("RunProxy Wire Protocol Tests")
struct RunProxyWireProtocolTests {
    @Test("request encodes and decodes correctly")
    func requestRoundTrip() throws {
        let request = RunProxyRequest(profile: "github-cli", command: ["gh", "pr", "list"], pid: 12345)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(RunProxyRequest.self, from: data)
        #expect(decoded.profile == "github-cli")
        #expect(decoded.command == ["gh", "pr", "list"])
        #expect(decoded.pid == 12345)
    }

    @Test("response with env encodes and decodes correctly")
    func responseAllowRoundTrip() throws {
        let response = RunProxyResponse(decision: .allow, env: ["GH_TOKEN": "secret123"])
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(RunProxyResponse.self, from: data)
        #expect(decoded.decision == .allow)
        #expect(decoded.env?["GH_TOKEN"] == "secret123")
    }

    @Test("deny response has nil env")
    func responseDeny() throws {
        let response = RunProxyResponse(decision: .deny, env: nil)
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(RunProxyResponse.self, from: data)
        #expect(decoded.decision == .deny)
        #expect(decoded.env == nil)
    }
}

// MARK: - Client Handler

@Suite("RunProxy Client Handler Tests")
struct RunProxyClientHandlerTests {

    @Test("ping sentinel gets allow response without invoking auth handler")
    func pingSentinelReturnsAllowWithoutEnv() async throws {
        let listenPath = NSTemporaryDirectory() + "run-ping-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(listenPath) }

        let proxy = RunProxy(
            listenPath: listenPath,
            authorizationHandler: { _, _ in
                Issue.record("auth handler must not run for ping sentinel")
                return RunProxyResponse(decision: .deny, env: nil)
            },
            failureSignal: { _ in },
            verifier: { fd in VerifiedConnection(fd: fd, identity: .trustedHelper, pid: ProcessInfo.processInfo.processIdentifier) }
        )
        try await proxy.start()

        do {
            // Connect to listen socket
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            #expect(fd >= 0)
            defer { close(fd) }

            var addr = SSHAgentConstants.makeUnixAddr(path: listenPath)
            let connectResult: Int32 = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            #expect(connectResult == 0)

            // Send a ping request
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            let ping = RunProxyRequest(
                profile: RunProxyProbeConstants.reservedPingSlug,
                command: [],
                pid: 0
            )
            try RunProxyWire.writeMessage(ping, to: handle)

            // Read response
            let response = try RunProxyWire.readMessage(RunProxyResponse.self, from: handle)
            #expect(response.decision == .allow)
            #expect(response.env == nil)
        } catch {
            await proxy.stop()
            throw error
        }
        await proxy.stop()
    }
}

// MARK: - Identifier Token Predicate

@MainActor
@Suite("Identifier Token Predicate Tests")
struct IdentifierTokenPredicateTests {
    @Test("accepts plain identifiers", arguments: [
        "gh", "pr", "list", "s3", "kube-system", "aws_profile", "python3",
    ])
    func accepts(_ token: String) {
        #expect(RunAuthWindowController.isIdentifierToken(token))
    }

    @Test(
        "rejects flags, paths, URLs, numeric and data-like tokens",
        arguments: [
            "-v", "--verbose", "--state=open",
            "/usr/bin/gh", "./script.sh", "repos/:owner/:repo",
            "s3://bucket/file", "https://example.com",
            "24529102039", "123abc", "script.py",
            "user@host", "KEY=value", "",
            "αβγ",       // non-ASCII letters (Greek)
            "élan",      // ASCII letter followed by non-ASCII letter
        ]
    )
    func rejects(_ token: String) {
        #expect(RunAuthWindowController.isIdentifierToken(token) == false)
    }
}

// MARK: - extractIdentifierTokens

@MainActor
@Suite("extractIdentifierTokens Tests")
struct ExtractIdentifierTokensTests {
    @Test("caps at 3 tokens")
    func capsAtThree() {
        let tokens = RunAuthWindowController.extractIdentifierTokens(
            from: ["a", "b", "c", "d", "e"]
        )
        #expect(tokens == ["a", "b", "c"])
    }

    @Test("stops at first non-identifier")
    func stopsAtNonIdentifier() {
        let tokens = RunAuthWindowController.extractIdentifierTokens(
            from: ["gh", "api", "repos/:owner/:repo", "--jq"]
        )
        #expect(tokens == ["gh", "api"])
    }

    @Test("stops at flag")
    func stopsAtFlag() {
        let tokens = RunAuthWindowController.extractIdentifierTokens(
            from: ["gh", "--verbose", "pr"]
        )
        #expect(tokens == ["gh"])
    }

    @Test("returns empty when first token is not an identifier")
    func firstTokenIsPath() {
        let tokens = RunAuthWindowController.extractIdentifierTokens(
            from: ["/usr/bin/gh", "status"]
        )
        #expect(tokens == [])
    }

    @Test("returns empty for empty input")
    func emptyInput() {
        let tokens = RunAuthWindowController.extractIdentifierTokens(from: [])
        #expect(tokens == [])
    }

    @Test("keeps a single bare identifier")
    func bareIdentifier() {
        let tokens = RunAuthWindowController.extractIdentifierTokens(from: ["gh"])
        #expect(tokens == ["gh"])
    }
}
