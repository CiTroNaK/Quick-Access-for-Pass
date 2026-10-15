import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

/// Synthetic metadata proofs only. Production must obtain proofs from its synchronization transaction.
nonisolated struct OfflineSyncPlanningFixture: Sendable {
    let database: DatabaseManager
    let repository: OfflineSnapshotRepository

    init(itemIDs: [String] = ["item"]) throws {
        database = try DatabaseManager(inMemory: true, passphrase: Data("synthetic-sync-planning".utf8))
        repository = OfflineSnapshotRepository(database: database)
        try database.upsertVaults([PassVault(id: "vault", name: "Vault", shareId: "share")])
        try database.upsertItems(itemIDs.map { offlineTestMetadata(id: $0, vaultID: "vault") })
    }

    func capture() async throws -> OfflineSyncCapture {
        try await repository.beginSyncCapture(operation: database.beginSyncOperation(), lifecycleGeneration: UUID())
    }

    func proofs(for capture: OfflineSyncCapture) async throws -> [OfflineSnapshotKey: OfflineSyncedMetadataProof] {
        try await database.reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT i.*, v.shareId AS sourceShareID, o.metadataGeneration AS selectedMetadataGeneration
                FROM items i JOIN vaults v ON v.id = i.vaultId
                LEFT JOIN offlineItems o ON o.itemId = i.id AND o.vaultId = i.vaultId
                """)
            let descriptors = try AutoFillCredentialDescriptor.fetchAll(db)
            var result: [OfflineSnapshotKey: OfflineSyncedMetadataProof] = [:]
            for row in rows {
                let item = try PassItem(row: row)
                let rawGeneration: String? = row["selectedMetadataGeneration"]
                let inputs = descriptors.filter { $0.itemID == item.id && $0.vaultID == item.vaultId }.map {
                    AutoFillDescriptorInput(vaultID: $0.vaultID, itemID: $0.itemID, shareID: $0.shareID,
                                            title: $0.title, username: $0.username,
                                            serviceIdentifier: $0.serviceIdentifier, hasTOTP: $0.hasTOTP)
                }
                let key = OfflineSnapshotKey(vaultId: item.vaultId, itemId: item.id, schemaVersion: OfflineSnapshotLimits.schemaVersion)
                result[key] = OfflineSyncedMetadataProof(
                    operationID: capture.operation.id, item: item, shareID: row["sourceShareID"], descriptorInputs: inputs,
                    metadataGeneration: rawGeneration.flatMap(UUID.init(uuidString:))
                )
            }
            return result
        }
    }

    func work(
        for capture: OfflineSyncCapture,
        proofs suppliedProofs: [OfflineSnapshotKey: OfflineSyncedMetadataProof]? = nil,
        sourceTimes: [String: Date]? = nil,
        allowMembershipExpansion: Bool = true
    ) async throws -> [OfflineSyncWork] {
        let evidence: [OfflineSnapshotKey: OfflineSyncedMetadataProof]
        if let suppliedProofs { evidence = suppliedProofs } else { evidence = try await proofs(for: capture) }
        let times = sourceTimes ?? Dictionary(uniqueKeysWithValues: evidence.values.map { ($0.item.id, $0.item.modifyTime) })
        return try await repository.syncWork(capture: capture, metadataProofs: evidence, sourceTimes: times,
                                             allowMembershipExpansion: allowMembershipExpansion)
    }

    func cache(itemID: String = "item", sourceTime: String = "1970-01-01T00:00:02Z") async throws {
        let request = try #require(try await repository.beginRequest(
            itemID: itemID, vaultID: "vault", shareID: "share", kind: .selection
        ))
        let repository = repository
        let codec = OfflineSnapshotCodec(keyMaterialProvider: OfflineFixtureKeys(), hasPersistedSnapshots: {
            try await repository.hasPersistedSnapshots()
        })
        let item = try offlineTestCLIItem(id: itemID, vaultID: "vault", shareID: "share", password: "synthetic", modifyTime: sourceTime)
        let prepared = try await codec.prepareSnapshot(from: item, for: request)
        #expect(try await repository.publish(prepared, for: request, refreshedAt: Date(timeIntervalSince1970: 3)))
    }

    func scalar(_ sql: String) async throws -> Int {
        // All callers supply fixed test-authored metadata-only SQL.
        try await database.reader.read { try Int.fetchOne($0, sql: sql) ?? 0 }
    }
}
