import CryptoKit
import Foundation

nonisolated struct OfflineSnapshotKey: Sendable, Hashable, Codable {
    let vaultId: String
    let itemId: String
    let schemaVersion: UInt8
}

nonisolated struct OfflineSnapshotCipher: Sendable {
    enum Error: Swift.Error, Equatable, Sendable {
        case invalidKey
        case invalidCiphertext
        case authenticationFailed
        case keyMismatch
        case unsupportedSchemaVersion
        case payloadTooLarge
    }

    private static let domain = "codes.petr.quick-access-for-pass.offline.snapshot"

    private let key: SymmetricKey
    let fingerprint: Data

    init(keyData: Data) throws {
        guard keyData.count == 32 else { throw Error.invalidKey }
        key = SymmetricKey(data: keyData)
        fingerprint = Data(SHA256.hash(data: keyData))
    }

    /// Strict snapshot format binding a sealed payload to its committed revision and key fingerprint.
    func seal(_ plaintext: Data, for identity: OfflineSnapshotIdentity) throws -> Data {
        try validate(identity: identity)
        guard plaintext.count <= OfflineSnapshotLimits.plaintextBytes else { throw Error.payloadTooLarge }
        let sealedBox = try AES.GCM.seal(
            plaintext,
            using: key,
            authenticating: authenticatedData(for: identity)
        )
        guard let combined = sealedBox.combined else { throw Error.invalidCiphertext }
        return combined
    }

    /// Strict snapshot format binding a sealed payload to its committed revision and key fingerprint.
    func open(_ ciphertext: Data, for identity: OfflineSnapshotIdentity) throws -> Data {
        try validate(identity: identity)
        guard ciphertext.count <= OfflineSnapshotLimits.ciphertextBytes else { throw Error.payloadTooLarge }
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(
                sealedBox,
                using: key,
                authenticating: authenticatedData(for: identity)
            )
        } catch let error as CryptoKitError {
            switch error {
            case .authenticationFailure:
                throw Error.authenticationFailed
            default:
                throw Error.invalidCiphertext
            }
        } catch {
            throw Error.invalidCiphertext
        }
    }


    private func validate(identity: OfflineSnapshotIdentity) throws {
        guard identity.key.schemaVersion == OfflineSnapshotLimits.schemaVersion else {
            throw Error.unsupportedSchemaVersion
        }
        guard identity.keyFingerprint.count == 32, identity.keyFingerprint == fingerprint else {
            throw Error.keyMismatch
        }
    }

    private func authenticatedData(for identity: OfflineSnapshotIdentity) -> Data {
        func appendLengthPrefixedUTF8(_ value: String, to data: inout Data) {
            let bytes = Data(value.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(bytes)
        }

        var data = Data()
        appendLengthPrefixedUTF8(Self.domain, to: &data)
        data.append(identity.key.schemaVersion)
        appendLengthPrefixedUTF8(identity.key.vaultId, to: &data)
        appendLengthPrefixedUTF8(identity.key.itemId, to: &data)
        var uuid = identity.revision.uuid
        withUnsafeBytes(of: &uuid) { data.append(contentsOf: $0) }
        data.append(identity.keyFingerprint)
        return data
    }
}
