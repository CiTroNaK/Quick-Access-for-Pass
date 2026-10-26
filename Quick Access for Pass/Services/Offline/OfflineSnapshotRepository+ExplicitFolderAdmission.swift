import Foundation
import GRDB

/// Invocation-owned metadata only; retained cached coverage is not publication authority.
nonisolated struct OfflineFolderRequestAdmission: Sendable {
    let catalog: FolderCatalogAdmissionProof
    let policies: [OfflineFolderSelection]
}

nonisolated extension OfflineSnapshotRepository {
    /// Called after reservation in the same writer transaction, before any content fetch.
    func explicitFolderAdmission(for key: OfflineSnapshotKey, in db: Database) throws -> OfflineFolderRequestAdmission? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT o.isManuallySelected,
                EXISTS(SELECT 1 FROM offlineVaults v WHERE v.vaultId = o.vaultId) AS vaultSelected
            FROM offlineItems o WHERE o.vaultId = ? AND o.itemId = ?
            """, arguments: [key.vaultId, key.itemId]) else { throw OfflinePersistenceError.itemUnavailable }
        if (row["isManuallySelected"] as Int) == 1 || (row["vaultSelected"] as Int) == 1 { return nil }
        guard let gate = folderFeatureGate,
              let catalog = try DatabaseManager.folderCatalogAdmissionProof(vaultID: key.vaultId, gate: gate, in: db) else {
            throw OfflinePersistenceError.itemUnavailable
        }
        let policies = try Self.folderSelections(itemID: key.itemId, vaultID: key.vaultId, in: db)
        guard !policies.isEmpty else { throw OfflinePersistenceError.itemUnavailable }
        return OfflineFolderRequestAdmission(catalog: catalog, policies: policies)
    }

    /// Writer-side revalidation cannot borrow a newer discovery or a later policy promotion.
    func permitsExplicitPublication(_ request: OfflineRequestToken, in db: Database) throws -> Bool {
        guard let original = request.folderAdmission else { return true }
        guard let gate = folderFeatureGate,
              try DatabaseManager.folderCatalogAdmissionProof(vaultID: request.key.vaultId, gate: gate, in: db) == original.catalog else { return false }
        let current = try Self.folderSelections(itemID: request.key.itemId, vaultID: request.key.vaultId, in: db)
        return original.policies.contains(where: current.contains) && gate.isCurrent(original.catalog.stamp)
    }
}
