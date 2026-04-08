import Testing
import Foundation
import Darwin
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

    @Test("no decision by default")
    func noDecision() throws {
        let db = try makeTestDB()
        let d = try db.findValidRunDecision(appIdentifier: "com.test", subcommand: "gh pr list", profileSlug: "github-cli")
        #expect(d == nil)
    }

    @Test("saves and retrieves decision")
    func saveAndFind() throws {
        let db = try makeTestDB()
        let expiry = Date().addingTimeInterval(300)
        try db.saveRunDecision(appIdentifier: "com.test", subcommand: "gh pr list", profileSlug: "github-cli", expiresAt: expiry)

        let d = try db.findValidRunDecision(appIdentifier: "com.test", subcommand: "gh pr list", profileSlug: "github-cli")
        #expect(d != nil)
        #expect(d?.subcommand == "gh pr list")
    }

    @Test("expired decision not returned")
    func expired() throws {
        let db = try makeTestDB()
        try db.saveRunDecision(appIdentifier: "com.test", subcommand: "gh pr list", profileSlug: "github-cli", expiresAt: Date().addingTimeInterval(-10))
        #expect(try db.findValidRunDecision(appIdentifier: "com.test", subcommand: "gh pr list", profileSlug: "github-cli") == nil)
    }

    @Test("different subcommands are separate")
    func subcommandsSeparate() throws {
        let db = try makeTestDB()
        try db.saveRunDecision(appIdentifier: "com.test", subcommand: "gh pr list", profileSlug: "github-cli", expiresAt: Date().addingTimeInterval(300))
        #expect(try db.findValidRunDecision(appIdentifier: "com.test", subcommand: "gh pr create", profileSlug: "github-cli") == nil)
        #expect(try db.findValidRunDecision(appIdentifier: "com.test", subcommand: "gh pr list", profileSlug: "github-cli") != nil)
    }

    @Test("different profiles are separate")
    func profilesSeparate() throws {
        let db = try makeTestDB()
        try db.saveRunDecision(appIdentifier: "com.test", subcommand: "gh pr list", profileSlug: "github-cli", expiresAt: Date().addingTimeInterval(300))
        #expect(try db.findValidRunDecision(appIdentifier: "com.test", subcommand: "gh pr list", profileSlug: "other-profile") == nil)
    }

    @Test("cleanup removes expired decisions")
    func cleanup() throws {
        let db = try makeTestDB()
        try db.saveRunDecision(appIdentifier: "app1", subcommand: "cmd1", profileSlug: "p1", expiresAt: Date().addingTimeInterval(-100))
        try db.saveRunDecision(appIdentifier: "app2", subcommand: "cmd2", profileSlug: "p2", expiresAt: Date().addingTimeInterval(300))
        try db.cleanupExpiredRunDecisions()
        let all = try db.allRunAuthDecisions()
        #expect(all.count == 1)
        #expect(all[0].appIdentifier == "app2")
    }

    @Test("remove specific decision")
    func remove() throws {
        let db = try makeTestDB()
        try db.saveRunDecision(appIdentifier: "app1", subcommand: "cmd1", profileSlug: "p1", expiresAt: Date().addingTimeInterval(300))
        try db.saveRunDecision(appIdentifier: "app2", subcommand: "cmd2", profileSlug: "p2", expiresAt: Date().addingTimeInterval(300))
        try db.removeRunAuthDecision(appIdentifier: "app1", subcommand: "cmd1", profileSlug: "p1")
        let all = try db.allRunAuthDecisions()
        #expect(all.count == 1)
        #expect(all[0].appIdentifier == "app2")
    }

    @Test("upsert overwrites existing decision")
    func upsert() throws {
        let db = try makeTestDB()
        try db.saveRunDecision(appIdentifier: "app1", subcommand: "cmd1", profileSlug: "p1", expiresAt: Date().addingTimeInterval(60))
        let newExpiry = Date().addingTimeInterval(3600)
        try db.saveRunDecision(appIdentifier: "app1", subcommand: "cmd1", profileSlug: "p1", expiresAt: newExpiry)
        let d = try db.findValidRunDecision(appIdentifier: "app1", subcommand: "cmd1", profileSlug: "p1")
        #expect(d != nil)
        #expect(abs((d?.expiresAt?.timeIntervalSinceReferenceDate ?? 0) - newExpiry.timeIntervalSinceReferenceDate) < 1.0)
    }
}

// MARK: - Subcommand Extraction

@MainActor
@Suite("Subcommand Extraction Tests")
struct SubcommandExtractionTests {
    @Test("extracts up to 3 tokens")
    func threeTokens() {
        let result = RunAuthWindowController.extractSubcommand(from: ["gh", "pr", "create", "--title", "Fix bug"])
        #expect(result == "gh pr create")
    }

    @Test("stops at first flag")
    func stopsAtFlag() {
        let result = RunAuthWindowController.extractSubcommand(from: ["gh", "--verbose", "pr", "list"])
        #expect(result == "gh")
    }

    @Test("caps at 3 tokens even without flags")
    func capsAtThree() {
        let result = RunAuthWindowController.extractSubcommand(from: ["gh", "api", "/repos/owner/repo", "extra"])
        #expect(result == "gh api /repos/owner/repo")
    }

    @Test("single token command")
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
