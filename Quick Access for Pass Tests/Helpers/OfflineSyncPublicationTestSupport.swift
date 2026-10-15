import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

nonisolated struct OfflineSyncPublicationFixture: Sendable {
    let planning: OfflineSyncPlanningFixture
    let itemIDs: [String]
    var database: DatabaseManager { planning.database }
    var repository: OfflineSnapshotRepository { planning.repository }

    init(itemIDs: [String] = ["item", "other"]) throws {
        self.itemIDs = itemIDs
        planning = try OfflineSyncPlanningFixture(itemIDs: itemIDs)
    }

    func selectAll() async throws {
        for id in itemIDs {
            _ = try await repository.selectItemManually(itemID: id, vaultID: "vault", shareID: "share")
        }
    }

    /// Uses the real transaction-produced proof path with synthetic incoming metadata.
    func work(_ capture: OfflineSyncCapture, incomingIDs: [String]? = nil) async throws -> [OfflineSyncWork] {
        let items = (incomingIDs ?? itemIDs).map { offlineTestMetadata(id: $0, vaultID: "vault") }
        let result = try await database.synchronizeMetadata(vaults: [PassVault(id: "vault", name: "Vault", shareId: "share")],
                                                           items: items, descriptors: [], operation: capture.operation)
        return try await planning.work(for: capture, proofs: result.offlineMetadataProofs)
    }

    func prepare(_ work: [OfflineSyncWork]) async throws -> [OfflineSyncPublication] {
        let repository = repository
        let codec = OfflineSnapshotCodec(keyMaterialProvider: OfflineFixtureKeys(), hasPersistedSnapshots: {
            try await repository.hasPersistedSnapshots()
        })
        var result: [OfflineSyncPublication] = []
        for candidate in work {
            let item = try offlineTestCLIItem(id: candidate.key.itemId, vaultID: candidate.key.vaultId,
                                             shareID: candidate.shareID, password: "synthetic", modifyTime: "1970-01-01T00:00:02Z")
            let prepared = try await codec.prepareSnapshot(from: item, for: OfflineSnapshotPreparationIdentity(
                key: candidate.key, shareID: candidate.shareID, itemType: candidate.itemType
            ))
            result.append(OfflineSyncPublication(work: candidate, prepared: prepared, refreshedAt: Date(timeIntervalSince1970: 41)))
        }
        return result
    }

    func baseline(_ itemID: String = "item") async throws -> Date? {
        try await database.reader.read {
            try Date.fetchOne($0, sql: "SELECT sourceModifyTime FROM offlineSnapshots WHERE itemId = ?", arguments: [itemID])
        }
    }

    func replace(_ publication: OfflineSyncPublication, key: OfflineSnapshotKey? = nil,
                 fingerprint: Data? = nil, payload: Data? = nil) -> OfflineSyncPublication {
        let snapshot = publication.prepared.snapshot
        let identity = OfflineSnapshotIdentity(key: key ?? snapshot.identity.key, revision: snapshot.identity.revision,
                                               keyFingerprint: fingerprint ?? snapshot.identity.keyFingerprint)
        return OfflineSyncPublication(work: publication.work, prepared: PreparedOfflineSnapshot(
            snapshot: EncryptedOfflineSnapshot(identity: identity, payload: payload ?? snapshot.payload),
            sourceModifyTime: publication.prepared.sourceModifyTime
        ), refreshedAt: publication.refreshedAt)
    }
}
