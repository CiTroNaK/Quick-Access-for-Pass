import Foundation

/// Operation-scoped encryption and decoding for offline snapshots.
nonisolated protocol OfflineSnapshotCoding: Sendable {
    func prepareSnapshot(from item: CLIItem, for request: OfflineRequestToken) async throws -> PreparedOfflineSnapshot
    func prepareSnapshot(from item: CLIItem, for identity: OfflineSnapshotPreparationIdentity) async throws -> PreparedOfflineSnapshot
    func decodeSnapshot(_ snapshot: EncryptedOfflineSnapshot) async throws -> CLIItem
}

nonisolated extension OfflineSnapshotCoding {
    func prepareSnapshot(from item: CLIItem, for request: OfflineRequestToken) async throws -> PreparedOfflineSnapshot {
        try await prepareSnapshot(from: item, for: OfflineSnapshotPreparationIdentity(
            key: request.key, shareID: request.shareID, itemType: request.itemType
        ))
    }
}

/// Encrypts and decrypts one snapshot at a time without retaining key or plaintext resources.
actor OfflineSnapshotCodec: OfflineSnapshotCoding {
    enum Error: Swift.Error, Equatable, Sendable {
        case keyUnavailable
        case invalidIdentity
        case payloadTooLarge
        case corruptSnapshot
        case unsupportedSchemaVersion
    }

    private let keyMaterialProvider: any OfflineSnapshotKeyProviding
    private let hasPersistedSnapshots: @Sendable () async throws -> Bool

    init(
        keyMaterialProvider: any OfflineSnapshotKeyProviding,
        hasPersistedSnapshots: @escaping @Sendable () async throws -> Bool
    ) {
        self.keyMaterialProvider = keyMaterialProvider
        self.hasPersistedSnapshots = hasPersistedSnapshots
    }

    func prepareSnapshot(from item: CLIItem, for request: OfflineSnapshotPreparationIdentity) async throws -> PreparedOfflineSnapshot {
        try Task.checkCancellation()
        try validate(request: request, item: item)
        var material = try await encryptionKeyMaterial()
        defer { material.resetBytes(in: 0..<material.count) }
        try Task.checkCancellation()

        let cipher: OfflineSnapshotCipher
        do {
            cipher = try OfflineSnapshotCipher(keyData: material)
        } catch {
            throw Error.keyUnavailable
        }
        var plaintext: Data
        do {
            plaintext = try JSONEncoder().encode(item)
        } catch {
            throw Error.corruptSnapshot
        }
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        try Task.checkCancellation()
        guard plaintext.count <= OfflineSnapshotLimits.plaintextBytes else {
            throw Error.payloadTooLarge
        }

        let identity = OfflineSnapshotIdentity(
            key: request.key,
            revision: UUID(),
            keyFingerprint: cipher.fingerprint
        )
        let payload: Data
        do {
            payload = try cipher.seal(plaintext, for: identity)
        } catch let error as OfflineSnapshotCipher.Error {
            throw map(error)
        } catch {
            throw Error.corruptSnapshot
        }
        try Task.checkCancellation()
        return PreparedOfflineSnapshot(
            snapshot: EncryptedOfflineSnapshot(identity: identity, payload: payload),
            sourceModifyTime: OfflineSourceModificationTime.parse(item.modifyTime)
        )
    }

    func decodeSnapshot(_ snapshot: EncryptedOfflineSnapshot) async throws -> CLIItem {
        try validate(snapshot: snapshot)
        guard var material = try await keyMaterialProvider.existingSnapshotKey() else {
            throw Error.keyUnavailable
        }
        defer { material.resetBytes(in: 0..<material.count) }

        let cipher: OfflineSnapshotCipher
        do {
            cipher = try OfflineSnapshotCipher(keyData: material)
        } catch {
            throw Error.keyUnavailable
        }
        guard cipher.fingerprint == snapshot.identity.keyFingerprint else {
            throw Error.keyUnavailable
        }

        var plaintext: Data
        do {
            plaintext = try cipher.open(snapshot.payload, for: snapshot.identity)
        } catch let error as OfflineSnapshotCipher.Error {
            throw map(error)
        } catch {
            throw Error.corruptSnapshot
        }
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        guard plaintext.count <= OfflineSnapshotLimits.plaintextBytes else {
            throw Error.payloadTooLarge
        }

        let item: CLIItem
        do {
            item = try JSONDecoder().decode(CLIItem.self, from: plaintext)
        } catch {
            throw Error.corruptSnapshot
        }
        guard item.id == snapshot.identity.key.itemId,
              item.vaultId == snapshot.identity.key.vaultId,
              item.state == "Active",
              !item.shareId.isEmpty else {
            throw Error.invalidIdentity
        }
        return item
    }

    private func encryptionKeyMaterial() async throws -> Data {
        if let existing = try await keyMaterialProvider.existingSnapshotKey() {
            return existing
        }
        guard try await hasPersistedSnapshots() == false else {
            throw Error.keyUnavailable
        }
        return try await keyMaterialProvider.createSnapshotKey()
    }

    private nonisolated func validate(request: OfflineSnapshotPreparationIdentity, item: CLIItem) throws {
        guard request.key.schemaVersion == OfflineSnapshotLimits.schemaVersion else {
            throw Error.unsupportedSchemaVersion
        }
        guard item.id == request.key.itemId,
              item.vaultId == request.key.vaultId,
              item.shareId == request.shareID,
              item.state == "Active",
              item.content.content.itemType == request.itemType else {
            throw Error.invalidIdentity
        }
    }

    private nonisolated func validate(snapshot: EncryptedOfflineSnapshot) throws {
        guard snapshot.identity.key.schemaVersion == OfflineSnapshotLimits.schemaVersion else {
            throw Error.unsupportedSchemaVersion
        }
        guard snapshot.identity.keyFingerprint.count == 32 else {
            throw Error.invalidIdentity
        }
        guard snapshot.payload.count >= 28, snapshot.payload.count <= OfflineSnapshotLimits.ciphertextBytes else {
            throw Error.payloadTooLarge
        }
    }

    private nonisolated func map(_ error: OfflineSnapshotCipher.Error) -> Error {
        switch error {
        case .invalidKey, .keyMismatch:
            .keyUnavailable
        case .payloadTooLarge:
            .payloadTooLarge
        case .unsupportedSchemaVersion:
            .unsupportedSchemaVersion
        case .invalidCiphertext, .authenticationFailed:
            .corruptSnapshot
        }
    }
}
