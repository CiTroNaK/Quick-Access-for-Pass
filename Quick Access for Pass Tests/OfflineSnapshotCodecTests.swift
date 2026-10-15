import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Offline snapshot codec")
struct OfflineSnapshotCodecTests {
    private let request = OfflineRequestToken(
        id: UUID(),
        key: OfflineSnapshotKey(vaultId: "vault", itemId: "item", schemaVersion: OfflineSnapshotLimits.schemaVersion),
        shareID: "share",
        metadataModifyTime: Date(timeIntervalSince1970: 2),
        itemType: .login,
        selectionGeneration: UUID(),
        metadataGeneration: UUID(),
        requestGeneration: UUID()
    )

    @Test func codecEncryptsAndDecodesAnAuthorizedCLIItem() async throws {
        let codec = OfflineSnapshotCodec(
            keyMaterialProvider: OfflineFixtureKeys(),
            hasPersistedSnapshots: { false }
        )
        let item = try offlineTestCLIItem(
            id: "item", vaultID: "vault", shareID: "share", password: "fake-password"
        )

        let snapshot = try await codec.prepareSnapshot(from: item, for: request)

        #expect(snapshot.snapshot.payload != Data("fake-password".utf8))
        #expect(snapshot.snapshot.identity.key == request.key)
        #expect(try await codec.decodeSnapshot(snapshot.snapshot).id == item.id)
    }

    @Test(arguments: [
        try offlineTestCLIItem(id: "other", vaultID: "vault", shareID: "share", password: "fake-password"),
        try offlineTestCLIItem(id: "item", vaultID: "other", shareID: "share", password: "fake-password"),
        try offlineTestCLIItem(id: "item", vaultID: "vault", shareID: "other", password: "fake-password")
    ])
    func codecRejectsMismatchedResponseIdentity(_ item: CLIItem) async throws {
        let codec = OfflineSnapshotCodec(keyMaterialProvider: OfflineFixtureKeys(), hasPersistedSnapshots: { false })

        await #expect(throws: OfflineSnapshotCodec.Error.invalidIdentity) {
            _ = try await codec.prepareSnapshot(from: item, for: request)
        }
    }

    @Test func codecRejectsMismatchedResponseType() async throws {
        let codec = OfflineSnapshotCodec(keyMaterialProvider: OfflineFixtureKeys(), hasPersistedSnapshots: { false })
        let noteJSON: [String: Any] = [
            "id": "item", "vault_id": "vault", "share_id": "share",
            "content": ["title": "Note", "note": "", "item_uuid": "content-item", "content": ["Note": NSNull()]],
            "state": "Active", "flags": [], "create_time": "", "modify_time": ""
        ]
        let note = try JSONDecoder().decode(
            CLIItem.self,
            from: JSONSerialization.data(withJSONObject: noteJSON, options: [.sortedKeys])
        )

        await #expect(throws: OfflineSnapshotCodec.Error.invalidIdentity) {
            _ = try await codec.prepareSnapshot(from: note, for: request)
        }
    }

    @Test func codecDoesNotCreateAKeyWhenCiphertextAlreadyExists() async throws {
        let keys = OfflineFixtureKeys(initialMaterial: nil)
        let codec = OfflineSnapshotCodec(keyMaterialProvider: keys, hasPersistedSnapshots: { true })
        let item = try offlineTestCLIItem(id: "item", vaultID: "vault", shareID: "share", password: "fake-password")

        await #expect(throws: OfflineSnapshotCodec.Error.keyUnavailable) {
            _ = try await codec.prepareSnapshot(from: item, for: request)
        }
        #expect(await keys.createCount() == 0)
    }

    @Test func codecLooksUpSnapshotKeyForEachOperation() async throws {
        let keys = OfflineFixtureKeys()
        let codec = OfflineSnapshotCodec(keyMaterialProvider: keys, hasPersistedSnapshots: { false })
        let item = try offlineTestCLIItem(id: "item", vaultID: "vault", shareID: "share", password: "fake-password")

        let snapshot = try await codec.prepareSnapshot(from: item, for: request)
        _ = try await codec.decodeSnapshot(snapshot.snapshot)

        #expect(await keys.existingLookupCount() == 2)
    }

    @Test func codecRejectsAuthenticatedMalformedJSON() async throws {
        let key = Data(repeating: 7, count: 32)
        let cipher = try OfflineSnapshotCipher(keyData: key)
        let identity = OfflineSnapshotIdentity(key: request.key, revision: UUID(), keyFingerprint: cipher.fingerprint)
        let malformed = EncryptedOfflineSnapshot(
            identity: identity,
            payload: try cipher.seal(Data("not-json".utf8), for: identity)
        )
        let codec = OfflineSnapshotCodec(
            keyMaterialProvider: OfflineFixtureKeys(initialMaterial: key),
            hasPersistedSnapshots: { true }
        )

        await #expect(throws: OfflineSnapshotCodec.Error.corruptSnapshot) {
            _ = try await codec.decodeSnapshot(malformed)
        }
    }

    @Test func corruptOrWrongKeySnapshotsAreRejectedWithoutMutation() async throws {
        let encoder = OfflineSnapshotCodec(keyMaterialProvider: OfflineFixtureKeys(), hasPersistedSnapshots: { false })
        let item = try offlineTestCLIItem(id: "item", vaultID: "vault", shareID: "share", password: "fake-password")
        let snapshot = try await encoder.prepareSnapshot(from: item, for: request)
        var payload = snapshot.snapshot.payload
        payload[0] ^= 1
        let corrupt = EncryptedOfflineSnapshot(identity: snapshot.snapshot.identity, payload: payload)

        await #expect(throws: OfflineSnapshotCodec.Error.corruptSnapshot) {
            _ = try await encoder.decodeSnapshot(corrupt)
        }

        let wrongKeyCodec = OfflineSnapshotCodec(
            keyMaterialProvider: OfflineFixtureKeys(initialMaterial: Data(repeating: 8, count: 32)),
            hasPersistedSnapshots: { true }
        )
        await #expect(throws: OfflineSnapshotCodec.Error.keyUnavailable) {
            _ = try await wrongKeyCodec.decodeSnapshot(snapshot.snapshot)
        }
    }

    @Test func codecRejectsUnsupportedSchemasAndOversizedCiphertextBeforeDecoding() async throws {
        let codec = OfflineSnapshotCodec(keyMaterialProvider: OfflineFixtureKeys(), hasPersistedSnapshots: { false })
        let item = try offlineTestCLIItem(id: "item", vaultID: "vault", shareID: "share", password: "fake-password")
        let snapshot = try await codec.prepareSnapshot(from: item, for: request)
        let unsupported = EncryptedOfflineSnapshot(
            identity: OfflineSnapshotIdentity(
                key: OfflineSnapshotKey(vaultId: "vault", itemId: "item", schemaVersion: 2),
                revision: snapshot.snapshot.identity.revision,
                keyFingerprint: snapshot.snapshot.identity.keyFingerprint
            ),
            payload: snapshot.snapshot.payload
        )
        await #expect(throws: OfflineSnapshotCodec.Error.unsupportedSchemaVersion) {
            _ = try await codec.decodeSnapshot(unsupported)
        }

        let oversized = EncryptedOfflineSnapshot(
            identity: snapshot.snapshot.identity,
            payload: Data(repeating: 0, count: OfflineSnapshotLimits.ciphertextBytes + 1)
        )
        await #expect(throws: OfflineSnapshotCodec.Error.payloadTooLarge) {
            _ = try await codec.decodeSnapshot(oversized)
        }
    }

    @Test(arguments: ["2026-10-01T12:00:00Z", "2026-10-01T12:00:00", "", "invalid"])
    func bothPreparationPathsRetainOnlyActualPayloadSourceTime(_ rawTime: String) async throws {
        let codec = OfflineSnapshotCodec(keyMaterialProvider: OfflineFixtureKeys(), hasPersistedSnapshots: { false })
        let item = try offlineTestCLIItem(id: "item", vaultID: "vault", shareID: "share", password: "synthetic", modifyTime: rawTime)
        let expected = OfflineSourceModificationTime.parse(rawTime)
        let byRequest = try await codec.prepareSnapshot(from: item, for: request)
        let byIdentity = try await codec.prepareSnapshot(from: item, for: OfflineSnapshotPreparationIdentity(
            key: request.key, shareID: request.shareID, itemType: request.itemType
        ))
        #expect(byRequest.sourceModifyTime == expected)
        #expect(byIdentity.sourceModifyTime == expected)
        #expect(byRequest.snapshot.identity.key == request.key)
        #expect(byIdentity.snapshot.identity.key == request.key)
        #expect(try await codec.decodeSnapshot(byIdentity.snapshot).id == item.id)
        if expected != nil { #expect(byRequest.sourceModifyTime != request.metadataModifyTime) }
    }
}
