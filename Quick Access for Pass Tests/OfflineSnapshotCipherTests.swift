import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Offline snapshot cipher")
struct OfflineSnapshotCipherTests {
    private let key = OfflineSnapshotKey(vaultId: "vault", itemId: "item", schemaVersion: OfflineSnapshotLimits.schemaVersion)

    @Test func strictCipherBindsRevisionAndKeyFingerprint() throws {
        let cipher = try OfflineSnapshotCipher(keyData: Data(repeating: 7, count: 32))
        let identity = OfflineSnapshotIdentity(key: key, revision: UUID(), keyFingerprint: cipher.fingerprint)
        let sealed = try cipher.seal(Data("fake-secret".utf8), for: identity)
        let substituted = OfflineSnapshotIdentity(key: key, revision: UUID(), keyFingerprint: cipher.fingerprint)
        #expect(throws: OfflineSnapshotCipher.Error.self) {
            try cipher.open(sealed, for: substituted)
        }
        let wrong = try OfflineSnapshotCipher(keyData: Data(repeating: 8, count: 32))
        #expect(throws: OfflineSnapshotCipher.Error.keyMismatch) {
            try wrong.open(sealed, for: identity)
        }
    }

    @Test(arguments: [
        OfflineSnapshotKey(vaultId: "other-vault", itemId: "item", schemaVersion: OfflineSnapshotLimits.schemaVersion),
        OfflineSnapshotKey(vaultId: "vault", itemId: "other-item", schemaVersion: OfflineSnapshotLimits.schemaVersion),
        OfflineSnapshotKey(vaultId: "vault", itemId: "item", schemaVersion: 2),
    ])
    func strictCipherRejectsChangedKeyComponents(_ substitutedKey: OfflineSnapshotKey) throws {
        let cipher = try OfflineSnapshotCipher(keyData: Data(repeating: 7, count: 32))
        let identity = OfflineSnapshotIdentity(key: key, revision: UUID(), keyFingerprint: cipher.fingerprint)
        let sealed = try cipher.seal(Data("secret".utf8), for: identity)
        let substituted = OfflineSnapshotIdentity(key: substitutedKey, revision: identity.revision, keyFingerprint: cipher.fingerprint)

        #expect(throws: OfflineSnapshotCipher.Error.self) {
            try cipher.open(sealed, for: substituted)
        }
    }

    @Test func strictCipherRejectsChangedFingerprintBeforeAES() throws {
        let cipher = try OfflineSnapshotCipher(keyData: Data(repeating: 7, count: 32))
        let identity = OfflineSnapshotIdentity(key: key, revision: UUID(), keyFingerprint: cipher.fingerprint)
        let sealed = try cipher.seal(Data("secret".utf8), for: identity)
        let mismatch = OfflineSnapshotIdentity(key: key, revision: identity.revision, keyFingerprint: Data(repeating: 8, count: 32))

        #expect(throws: OfflineSnapshotCipher.Error.keyMismatch) {
            try cipher.open(sealed, for: mismatch)
        }
    }

    @Test func strictCipherRejectsTamperedCiphertextNonceAndTag() throws {
        let cipher = try OfflineSnapshotCipher(keyData: Data(repeating: 7, count: 32))
        let identity = OfflineSnapshotIdentity(key: key, revision: UUID(), keyFingerprint: cipher.fingerprint)
        let sealed = try cipher.seal(Data("secret".utf8), for: identity)

        for index in [0, 12, sealed.count - 1] {
            var tampered = sealed
            tampered[index] ^= 1
            #expect(throws: OfflineSnapshotCipher.Error.authenticationFailed) {
                try cipher.open(tampered, for: identity)
            }
        }
    }

    @Test func strictCipherUsesUniqueNoncesAndOpensBothPayloads() throws {
        let cipher = try OfflineSnapshotCipher(keyData: Data(repeating: 7, count: 32))
        let identity = OfflineSnapshotIdentity(key: key, revision: UUID(), keyFingerprint: cipher.fingerprint)
        let plaintext = Data("same bytes".utf8)
        let first = try cipher.seal(plaintext, for: identity)
        let second = try cipher.seal(plaintext, for: identity)

        #expect(first != second)
        #expect(try cipher.open(first, for: identity) == plaintext)
        #expect(try cipher.open(second, for: identity) == plaintext)
    }

    @Test(arguments: [0, 1, OfflineSnapshotLimits.plaintextBytes])
    func strictCipherSupportsPlaintextBoundarySizes(_ size: Int) throws {
        let cipher = try OfflineSnapshotCipher(keyData: Data(repeating: 7, count: 32))
        let identity = OfflineSnapshotIdentity(key: key, revision: UUID(), keyFingerprint: cipher.fingerprint)
        let plaintext = Data(repeating: 5, count: size)
        let sealed = try cipher.seal(plaintext, for: identity)

        #expect(sealed.count == size + 28)
        #expect(try cipher.open(sealed, for: identity) == plaintext)
    }

    @Test func strictCipherRejectsOversizedPayloads() throws {
        let cipher = try OfflineSnapshotCipher(keyData: Data(repeating: 7, count: 32))
        let identity = OfflineSnapshotIdentity(key: key, revision: UUID(), keyFingerprint: cipher.fingerprint)
        #expect(throws: OfflineSnapshotCipher.Error.payloadTooLarge) {
            try cipher.seal(Data(repeating: 0, count: OfflineSnapshotLimits.plaintextBytes + 1), for: identity)
        }
        #expect(throws: OfflineSnapshotCipher.Error.payloadTooLarge) {
            try cipher.open(Data(repeating: 0, count: OfflineSnapshotLimits.ciphertextBytes + 1), for: identity)
        }
    }

    @Test(arguments: [0, 31, 33])
    func invalidKeyLengthsAreRejected(_ length: Int) {
        #expect(throws: OfflineSnapshotCipher.Error.invalidKey) {
            try OfflineSnapshotCipher(keyData: Data(repeating: 1, count: length))
        }
    }

    @Test func delimiterCollisionIDsProduceDistinctAuthenticatedData() throws {
        let cipher = try OfflineSnapshotCipher(keyData: Data(repeating: 7, count: 32))
        let firstKey = OfflineSnapshotKey(vaultId: "a\u{0}b", itemId: "c", schemaVersion: OfflineSnapshotLimits.schemaVersion)
        let secondKey = OfflineSnapshotKey(vaultId: "a", itemId: "b\u{0}c", schemaVersion: OfflineSnapshotLimits.schemaVersion)
        let revision = UUID()
        let first = OfflineSnapshotIdentity(key: firstKey, revision: revision, keyFingerprint: cipher.fingerprint)
        let second = OfflineSnapshotIdentity(key: secondKey, revision: revision, keyFingerprint: cipher.fingerprint)

        let sealed = try cipher.seal(Data("secret".utf8), for: first)
        #expect(throws: OfflineSnapshotCipher.Error.authenticationFailed) {
            try cipher.open(sealed, for: second)
        }
    }

    @Test func unsupportedSchemaFailsBeforeCipherOperation() throws {
        let cipher = try OfflineSnapshotCipher(keyData: Data(repeating: 7, count: 32))
        let unsupported = OfflineSnapshotIdentity(
            key: .init(vaultId: "vault", itemId: "item", schemaVersion: 2),
            revision: UUID(),
            keyFingerprint: cipher.fingerprint
        )
        #expect(throws: OfflineSnapshotCipher.Error.unsupportedSchemaVersion) {
            try cipher.seal(Data("secret".utf8), for: unsupported)
        }
    }

}
