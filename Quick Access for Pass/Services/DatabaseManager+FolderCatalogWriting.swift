import Foundation
import GRDB

nonisolated extension DatabaseManager {
    static func writeFolderCatalogs(_ outcomes: [String: FolderCatalogFetchOutcome], vaults: [PassVault],
                                    baseline: [String: FolderCatalogStoredMetadata], gate: FolderFeatureGate?,
                                    in db: Database) throws -> FolderCatalogWriteResult {
        var result = FolderCatalogWriteResult()
        let items = try Row.fetchAll(db, sql: "SELECT id, vaultId FROM items")
        var itemIDsByVault: [String: Set<String>] = [:]
        for row in items { itemIDsByVault[row["vaultId"], default: []].insert(row["id"]) }
        try db.execute(sql: """
            DELETE FROM folderItemMemberships WHERE NOT EXISTS (
                SELECT 1 FROM items i WHERE i.id = folderItemMemberships.itemId AND i.vaultId = folderItemMemberships.vaultId
            )
            """)
        for vault in vaults {
            let previous = baseline[vault.id] ?? FolderCatalogStoredMetadata()
            let itemIDs = itemIDsByVault[vault.id, default: []]
            let accepted: ValidatedFolderCatalog?
            if case .complete(let catalog) = outcomes[vault.id], let gate,
               catalog.vaultID == vault.id, catalog.shareID == vault.shareId,
               Set(catalog.itemMemberships.keys) == itemIDs, gate.isCurrent(catalog.stamp) {
                accepted = catalog
            } else { accepted = nil }
            let parents = accepted.map { Dictionary(uniqueKeysWithValues: $0.folders.map { ($0.id, $0.parentID) }) }
                ?? previous.parentsByID
            let memberships = accepted?.itemMemberships ?? previous.memberships.filter { itemIDs.contains($0.key) }
            let changed = parents != previous.parentsByID || memberships != previous.memberships
            let generation = changed ? UUID() : (previous.generation ?? UUID())
            if changed {
                let ids = Set(previous.memberships.keys).union(memberships.keys)
                result.affectedItemKeys.formUnion(ids.map {
                    OfflineSnapshotKey(vaultId: vault.id, itemId: $0, schemaVersion: OfflineSnapshotLimits.schemaVersion)
                })
            }
            if let catalog = accepted, let gate {
                try writeAcceptedFolderCatalog(catalog, previous: previous, structureChanged: changed, in: db)
                let observation = UUID()
                try db.execute(sql: """
                    INSERT INTO folderCatalogState
                    (vaultId, membershipGeneration, observationId, selectionGeneration, probeRevision, reconciliationStatus)
                    VALUES (?, ?, ?, ?, ?, 'fresh')
                    ON CONFLICT(vaultId) DO UPDATE SET membershipGeneration = excluded.membershipGeneration,
                        observationId = excluded.observationId, selectionGeneration = excluded.selectionGeneration,
                        probeRevision = excluded.probeRevision, reconciliationStatus = 'fresh'
                    """, arguments: [vault.id, generation.uuidString, observation.uuidString,
                                      catalog.stamp.selectionGeneration.uuidString, catalog.stamp.probeRevision.uuidString])
                result.proofsByVaultID[vault.id] = try folderCatalogAdmissionProof(vaultID: vault.id, gate: gate, in: db)
            } else if previous.status != "deferred" || changed || previous.generation == nil {
                // Retain old membership/stamps. Deferred state cannot authorize additions.
                try db.execute(sql: """
                    INSERT INTO folderCatalogState (vaultId, membershipGeneration, observationId, reconciliationStatus)
                    VALUES (?, ?, ?, 'deferred')
                    ON CONFLICT(vaultId) DO UPDATE SET membershipGeneration = excluded.membershipGeneration,
                        observationId = excluded.observationId, reconciliationStatus = 'deferred'
                    """, arguments: [vault.id, generation.uuidString, UUID().uuidString])
            }
        }
        return result
    }

    private static func writeAcceptedFolderCatalog(_ catalog: ValidatedFolderCatalog,
                                                   previous: FolderCatalogStoredMetadata,
                                                   structureChanged: Bool, in db: Database) throws {
        let upsert = try db.makeStatement(sql: """
            INSERT INTO folders (vaultId, id, name, parentId) VALUES (?, ?, ?, ?)
            ON CONFLICT(vaultId, id) DO UPDATE SET name = excluded.name, parentId = excluded.parentId
            WHERE name IS NOT excluded.name OR parentId IS NOT excluded.parentId
            """)
        for folder in catalog.folders {
            try upsert.execute(arguments: [catalog.vaultID, folder.id, folder.name, folder.parentID])
        }
        guard structureChanged else { return }
        try db.execute(sql: "DELETE FROM folderItemMemberships WHERE vaultId = ?", arguments: [catalog.vaultID])
        let membershipInsert = try db.makeStatement(sql: "INSERT INTO folderItemMemberships (vaultId, itemId, folderId) VALUES (?, ?, ?)")
        for (itemID, membership) in catalog.itemMemberships {
            let folderID: String?
            switch membership {
            case .root: folderID = nil
            case .folder(let id): folderID = id
            case .unknown: throw FolderCatalogError.incompleteEvidence
            }
            try membershipInsert.execute(arguments: [catalog.vaultID, itemID, folderID])
        }
        let stale = Set(previous.parentsByID.keys).subtracting(catalog.folders.map(\.id))
        let delete = try db.makeStatement(sql: "DELETE FROM folders WHERE vaultId = ? AND id = ?")
        for id in stale { try delete.execute(arguments: [catalog.vaultID, id]) }
        try db.execute(sql: "DELETE FROM folderAncestors WHERE vaultId = ?", arguments: [catalog.vaultID])
        // One set-based expansion, only after immutable graph/depth/count validation.
        try db.execute(sql: """
            WITH RECURSIVE ancestry(folderId, ancestorId, depth) AS (
                SELECT id, id, 0 FROM folders WHERE vaultId = ?
                UNION ALL
                SELECT a.folderId, f.parentId, a.depth + 1 FROM ancestry a
                JOIN folders f ON f.vaultId = ? AND f.id = a.ancestorId WHERE f.parentId IS NOT NULL
            )
            INSERT INTO folderAncestors (vaultId, folderId, ancestorId, depth)
            SELECT ?, folderId, ancestorId, depth FROM ancestry
            """, arguments: [catalog.vaultID, catalog.vaultID, catalog.vaultID])
    }
}
