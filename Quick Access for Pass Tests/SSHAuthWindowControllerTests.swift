import Foundation
import Testing
@testable import Quick_Access_for_Pass

@MainActor
@Suite("SSHAuthWindowController Tests")
struct SSHAuthWindowControllerTests {
    @Test("another host or command's session approval cannot override a persisted denial", arguments: ["host", "command"])
    func sessionApprovalDoesNotOverrideOtherContextDenial(difference: String) async throws {
        let fixture = try SSHAuthorizationFixture(difference: difference)
        try fixture.database.saveDecision(
            appIdentifier: "com.test.terminal:blocked.example:git fetch",
            keyFingerprint: fixture.keyBlob.sha256Hex,
            expiresAt: nil,
            allowed: false
        )
        let first = Task {
            await fixture.controller.authorize(keyBlob: fixture.keyBlob, connection: fixture.firstConnection)
        }
        var prompts = fixture.prompts.makeAsyncIterator()
        let prompt = try #require(await prompts.next())
        prompt.onResult(true, .doNotRemember)
        #expect(await first.value == .allow)

        #expect(fixture.controller.cachedAuthorizationResult(
            for: fixture.keyBlob, connection: fixture.secondConnection
        ) == .deny)
        #expect(await fixture.controller.authorize(
            keyBlob: fixture.keyBlob, connection: fixture.secondConnection
        ) == .deny)
    }

    @Test("another command's session denial cannot override a persisted approval")
    func sessionDenialDoesNotOverrideOtherContextApproval() async throws {
        let fixture = try SSHAuthorizationFixture(difference: "command")
        try fixture.database.saveDecision(
            appIdentifier: "com.test.terminal:blocked.example:git fetch",
            keyFingerprint: fixture.keyBlob.sha256Hex,
            expiresAt: nil,
            allowed: true
        )
        let first = Task {
            await fixture.controller.authorize(keyBlob: fixture.keyBlob, connection: fixture.firstConnection)
        }
        var prompts = fixture.prompts.makeAsyncIterator()
        let prompt = try #require(await prompts.next())
        prompt.onResult(false, .doNotRemember)
        #expect(await first.value == .deny)

        #expect(fixture.controller.cachedAuthorizationResult(
            for: fixture.keyBlob, connection: fixture.secondConnection
        ) == .allow)
    }

    @Test("queued requests in another context require their own decision", arguments: ["host", "command"])
    func queuedRequestDoesNotInheritOtherContextApproval(difference: String) async throws {
        let fixture = try SSHAuthorizationFixture(difference: difference, denySubsequentPrompts: true)
        let first = Task {
            await fixture.controller.authorize(keyBlob: fixture.keyBlob, connection: fixture.firstConnection)
        }
        var prompts = fixture.prompts.makeAsyncIterator()
        let prompt = try #require(await prompts.next())
        let second = Task {
            await fixture.controller.authorize(keyBlob: fixture.keyBlob, connection: fixture.secondConnection)
        }
        var identifications = fixture.identifications.makeAsyncIterator()
        while let pid = await identifications.next() {
            if pid == fixture.secondConnection.pid { break }
        }
        prompt.onResult(true, .doNotRemember)

        #expect(await first.value == .allow)
        #expect(await second.value == .deny)
        #expect(fixture.promptCount == 2)
    }

    @Test("queued requests in the same context reuse one decision", arguments: [false, true])
    func queuedSameContextRequestsReuseDecision(allowed: Bool) async throws {
        let fixture = try SSHAuthorizationFixture(difference: "none")
        let first = Task {
            await fixture.controller.authorize(keyBlob: fixture.keyBlob, connection: fixture.firstConnection)
        }
        var prompts = fixture.prompts.makeAsyncIterator()
        let prompt = try #require(await prompts.next())
        let second = Task {
            await fixture.controller.authorize(keyBlob: fixture.keyBlob, connection: fixture.secondConnection)
        }
        var identifications = fixture.identifications.makeAsyncIterator()
        while let pid = await identifications.next() {
            if pid == fixture.secondConnection.pid { break }
        }
        prompt.onResult(allowed, .doNotRemember)

        let expected: SSHAuthorizationResult = allowed ? .allow : .deny
        #expect(await first.value == expected)
        #expect(await second.value == expected)
        #expect(fixture.promptCount == 1)
    }

    @Test("persisted denial denies the matching signing request")
    func persistedDenialDeniesSigningRequest() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let controller = SSHAuthWindowController(
            databaseManager: database,
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
            callbacks: .noop
        )
        let connection = VerifiedConnection(
            fd: -1,
            identity: .trustedHelper,
            pid: ProcessInfo.processInfo.processIdentifier
        )
        let keyBlob = Data("test-key".utf8)
        let clientInfo = ProcessIdentifier.identifyRequester(of: connection)
        let identity = SSHAuthorizationIdentity(connection: connection, clientInfo: clientInfo)
        try database.saveDecision(
            appIdentifier: identity.persistentCacheID,
            keyFingerprint: keyBlob.sha256Hex,
            expiresAt: Date().addingTimeInterval(300),
            allowed: false
        )

        let result = await controller.authorize(keyBlob: keyBlob, connection: connection)

        #expect(result == .deny)
    }
}

/// Replaces process discovery and presentation, while exercising real controller and database decisions.
@MainActor
private final class SSHAuthorizationFixture {
    @MainActor
    private final class PresentationRecorder {
        var count = 0
    }

    let database: DatabaseManager
    let keyBlob = Data("test-key".utf8)
    let firstConnection = VerifiedConnection(fd: -1, identity: .trustedHelper, pid: 100)
    let secondConnection = VerifiedConnection(fd: -1, identity: .trustedHelper, pid: 200)
    let prompts: AsyncStream<SSHAuthRequest>
    let identifications: AsyncStream<Int32>
    let controller: SSHAuthWindowController
    private let recorder: PresentationRecorder
    var promptCount: Int { recorder.count }

    init(difference: String, denySubsequentPrompts: Bool = false) throws {
        database = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let recorder = PresentationRecorder()
        self.recorder = recorder
        let promptChannel = AsyncStream<SSHAuthRequest>.makeStream()
        let identityChannel = AsyncStream<Int32>.makeStream()
        prompts = promptChannel.stream
        identifications = identityChannel.stream
        let firstInfo = SSHClientInfo(
            name: "Terminal", bundleIdentifier: "com.test.terminal", bundleURL: nil,
            command: "ssh git@\(difference == "host" ? "allowed.example" : "blocked.example")",
            triggerCommand: difference == "command" ? "git push" : "git fetch",
            showCommand: true, batchMode: false
        )
        let secondInfo = SSHClientInfo(
            name: "Terminal", bundleIdentifier: "com.test.terminal", bundleURL: nil,
            command: "ssh git@blocked.example", triggerCommand: "git fetch",
            showCommand: true, batchMode: false
        )
        controller = SSHAuthWindowController(
            databaseManager: database,
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
            callbacks: .noop,
            identifyRequester: { connection in
                identityChannel.continuation.yield(connection.pid)
                return connection.pid == 100 ? firstInfo : secondInfo
            },
            presentDialog: { request in
                recorder.count += 1
                promptChannel.continuation.yield(request)
                if denySubsequentPrompts, recorder.count > 1 {
                    request.onResult(false, .doNotRemember)
                }
            }
        )
    }
}
