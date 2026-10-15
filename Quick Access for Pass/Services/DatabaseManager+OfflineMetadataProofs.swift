import Foundation
import GRDB

nonisolated extension DatabaseManager {
    /// Evidence is produced before this transaction commits, never reconstructed by a later read.
    static func offlineMetadataProofs(
        items: [PassItem], vaults: [PassVault], descriptors: [AutoFillDescriptorInput], operationID: UUID?, in db: Database
    ) throws -> [OfflineSnapshotKey: OfflineSyncedMetadataProof] {
        guard let operationID else { return [:] }
        let incomingItems = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        let incomingVaults = Dictionary(vaults.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        let distinctInputs = Dictionary(descriptors.map { ($0.identityKey, $0) }, uniquingKeysWith: { _, newest in newest })
        let inputsByItem = Dictionary(grouping: distinctInputs.values, by: {
            OfflineSnapshotKey(vaultId: $0.vaultID, itemId: $0.itemID, schemaVersion: OfflineSnapshotLimits.schemaVersion)
        })
        let selectedRows = try Row.fetchAll(db, sql: "SELECT itemId, vaultId, metadataGeneration FROM offlineItems")
        var selectedKeys: Set<OfflineSnapshotKey> = []
        var generations: [OfflineSnapshotKey: UUID] = [:]
        for row in selectedRows {
            let key = OfflineSnapshotKey(vaultId: row["vaultId"], itemId: row["itemId"], schemaVersion: OfflineSnapshotLimits.schemaVersion)
            selectedKeys.insert(key)
            let raw: String = row["metadataGeneration"]
            generations[key] = UUID(uuidString: raw)
        }
        var proofs: [OfflineSnapshotKey: OfflineSyncedMetadataProof] = [:]
        for item in incomingItems.values {
            // Retained undecoded items and absent incoming share context cannot mint new source evidence.
            guard let vault = incomingVaults[item.vaultId] else { continue }
            let key = OfflineSnapshotKey(vaultId: item.vaultId, itemId: item.id, schemaVersion: OfflineSnapshotLimits.schemaVersion)
            if selectedKeys.contains(key), generations[key] == nil { continue }
            proofs[key] = OfflineSyncedMetadataProof(operationID: operationID, item: item, shareID: vault.shareId,
                                                     descriptorInputs: inputsByItem[key] ?? [], metadataGeneration: generations[key])
        }
        return proofs
    }
}
