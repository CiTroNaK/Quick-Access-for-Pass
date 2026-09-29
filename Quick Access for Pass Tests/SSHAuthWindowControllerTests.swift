import Foundation
import Testing
@testable import Quick_Access_for_Pass

@MainActor
@Suite("SSHAuthWindowController Tests")
struct SSHAuthWindowControllerTests {
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
