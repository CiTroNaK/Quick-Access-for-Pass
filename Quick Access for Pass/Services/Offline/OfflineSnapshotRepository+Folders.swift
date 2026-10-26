import Foundation
import GRDB

nonisolated extension OfflineSnapshotRepository {
    func setFolderSelected(_ selected: Bool, folderID: String, vaultID: String,
                           featureStamp: FolderFeatureStamp?) async throws -> OfflineFolderSelection? {
        do {
            let scope: OfflineReleaseMutationScope = selected ? .none : .folderOnly(vaultID: vaultID, folderID: folderID)
            let result = try await database.writeOfflineMutation(submissionScope: scope) { db in
                if selected {
                    guard let gate = folderFeatureGate, let featureStamp, gate.isCurrent(featureStamp),
                          let proof = try DatabaseManager.folderCatalogAdmissionProof(vaultID: vaultID, gate: gate, in: db),
                          proof.stamp == featureStamp,
                          try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM folders WHERE vaultId = ? AND id = ?)",
                                            arguments: [vaultID, folderID]) == true else {
                        throw OfflinePersistenceError.itemUnavailable
                    }
                    let generation = UUID()
                    try db.execute(sql: """
                        INSERT INTO offlineFolders (vaultId, folderId, policyGeneration, selectedAt) VALUES (?, ?, ?, ?)
                        ON CONFLICT(vaultId, folderId) DO UPDATE SET policyGeneration = excluded.policyGeneration, selectedAt = excluded.selectedAt
                        """, arguments: [vaultID, folderID, generation.uuidString, Date()])
                    try db.execute(sql: """
                        DELETE FROM offlineItemExclusions WHERE vaultId = ? AND itemId IN (
                            SELECT fm.itemId FROM folderItemMemberships fm
                            JOIN folderAncestors fa ON fa.vaultId = fm.vaultId AND fa.folderId = fm.folderId
                            WHERE fm.vaultId = ? AND fa.ancestorId = ?)
                        """, arguments: [vaultID, vaultID, folderID])
                    return OfflineMutationUpdate(value: (Optional(OfflineFolderSelection(vaultID: vaultID, folderID: folderID,
                                                                                         generation: generation)), false),
                        manualPromotions: [], automaticPromotions: try Self.automaticPromotions(in: db, adding: .folder(vaultID: vaultID, folderID: folderID)))
                }
                try db.execute(sql: "DELETE FROM offlineFolders WHERE vaultId = ? AND folderId = ?", arguments: [vaultID, folderID])
                let removedPolicy = db.changesCount > 0
                try db.execute(sql: "DELETE FROM offlineItems AS o WHERE o.vaultId = ? AND NOT \(OfflineSelectionSQL.effectiveSelection)",
                               arguments: [vaultID])
                return OfflineMutationUpdate(value: (Optional<OfflineFolderSelection>.none, removedPolicy || db.changesCount > 0),
                                             manualPromotions: [])
            }
            await checkpointAfterOfflineDeletion(result.1)
            return result.0
        } catch let error as OfflinePersistenceError { throw error } catch { throw OfflinePersistenceError.persistenceFailed }
    }

    /// Retained folder coverage authorizes cached release, not a new content fetch.
    /// Independent manual/whole-vault consent needs no folder capability or discovery.
    func permitsSelectedContentFetch(for key: OfflineSnapshotKey, in db: Database) throws -> Bool {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT o.isManuallySelected,
                EXISTS(SELECT 1 FROM offlineVaults vs WHERE vs.vaultId = o.vaultId) AS vaultSelected
            FROM offlineItems o WHERE o.vaultId = ? AND o.itemId = ? AND \(OfflineSelectionSQL.effectiveSelection)
            """, arguments: [key.vaultId, key.itemId]) else { return false }
        if (row["isManuallySelected"] as Int) == 1 || (row["vaultSelected"] as Int) == 1 { return true }
        guard let gate = folderFeatureGate else { return false }
        return try DatabaseManager.folderCatalogAdmissionProof(vaultID: key.vaultId, gate: gate, in: db) != nil
    }

    /// Survivors are read while service admission is blocked, before the destructive writer.
    func selectionKeysSurviving(removal: OfflineAutomaticCoverage) async throws -> Set<OfflineSnapshotKey> {
        let vaultID: String
        let excludesVault: Bool
        let folderID: String?
        switch removal {
        case .vault(let id): vaultID = id; excludesVault = true; folderID = nil
        case .folder(let id, let folder): vaultID = id; excludesVault = false; folderID = folder
        }
        do {
            return try await database.reader.read { db in
                var arguments: StatementArguments = [vaultID]
                if let folderID { arguments += [folderID] }
                let rows = try Row.fetchAll(db, sql: """
                    SELECT o.itemId FROM offlineItems o WHERE o.vaultId = ? AND (
                        o.isManuallySelected = 1 OR (
                            \(OfflineSelectionSQL.automaticCoverage(for: .selection, excludingVault: excludesVault, excludingFolder: folderID != nil))
                            AND NOT EXISTS(SELECT 1 FROM offlineItemExclusions x WHERE x.vaultId = o.vaultId AND x.itemId = o.itemId)))
                    """, arguments: arguments)
                return Set(rows.map { OfflineSnapshotKey(vaultId: vaultID, itemId: $0["itemId"], schemaVersion: OfflineSnapshotLimits.schemaVersion) })
            }
        } catch { throw OfflinePersistenceError.persistenceFailed }
    }

    static func folderSelections(itemID: String, vaultID: String, in db: Database) throws -> [OfflineFolderSelection] {
        try Row.fetchAll(db, sql: """
            SELECT fs.folderId, fs.policyGeneration \(OfflineSelectionSQL.folderPolicyRows(for: .bound))
            ORDER BY fa.depth, fs.folderId
            """, arguments: [itemID, vaultID]).map { row in
                guard let generation = UUID(uuidString: row["policyGeneration"]) else { throw OfflinePersistenceError.persistenceFailed }
                return OfflineFolderSelection(vaultID: vaultID, folderID: row["folderId"], generation: generation)
            }
    }

    /// One row per affected selected item, never an item × ancestor expansion. The
    /// keyed result lets settlement visit captures once instead of scanning this catalog under its lock.
    static func automaticPromotions(in db: Database, adding source: OfflineAutomaticCoverage) throws -> [OfflineSnapshotKey: OfflineAutomaticPromotion] {
        let vaultID: String
        let predicate: String
        var arguments: StatementArguments
        switch source {
        case .vault(let id):
            vaultID = id
            predicate = "EXISTS(SELECT 1 FROM offlineVaults vs WHERE vs.vaultId = o.vaultId)"
            arguments = [id]
        case .folder(let id, let folderID):
            vaultID = id
            predicate = "EXISTS(SELECT 1 \(OfflineSelectionSQL.folderPolicyRows(for: .selection)) AND fs.folderId = ?)"
            arguments = [id, folderID]
        }
        let rows = try Row.fetchAll(db, sql: """
            SELECT o.itemId, o.selectionGeneration FROM offlineItems o
            WHERE o.vaultId = ? AND \(predicate) AND o.isManuallySelected = 0
              AND NOT EXISTS(SELECT 1 FROM offlineItemExclusions x WHERE x.vaultId = o.vaultId AND x.itemId = o.itemId)
            """, arguments: arguments)
        return try Dictionary(uniqueKeysWithValues: rows.map { row in
            guard let generation = UUID(uuidString: row["selectionGeneration"]) else { throw OfflinePersistenceError.persistenceFailed }
            let key = OfflineSnapshotKey(vaultId: vaultID, itemId: row["itemId"], schemaVersion: OfflineSnapshotLimits.schemaVersion)
            return (key, OfflineAutomaticPromotion(key: key, selectionGeneration: generation, coverage: [source]))
        })
    }

    static func automaticCoverage(in db: Database, key: OfflineSnapshotKey) throws -> Set<OfflineAutomaticCoverage> {
        Set(try automaticCoverageRows(in: db, vaultID: key.vaultId, itemID: key.itemId).map {
            coverageSource($0, vaultID: key.vaultId)
        })
    }

    private static func coverageSource(_ row: Row, vaultID: String) -> OfflineAutomaticCoverage {
        row["sourceKind"] as String == "vault" ? .vault(vaultID) : .folder(vaultID: vaultID, folderID: row["sourceID"])
    }

    private static func automaticCoverageRows(in db: Database, vaultID: String, itemID: String? = nil) throws -> [Row] {
        try Row.fetchAll(db, sql: """
            SELECT o.itemId, o.selectionGeneration, 'vault' AS sourceKind, vs.vaultId AS sourceID
            FROM offlineItems o JOIN offlineVaults vs ON vs.vaultId = o.vaultId
            WHERE o.vaultId = ? AND (? IS NULL OR o.itemId = ?) AND o.isManuallySelected = 0
              AND NOT EXISTS(SELECT 1 FROM offlineItemExclusions x WHERE x.vaultId = o.vaultId AND x.itemId = o.itemId)
            UNION ALL
            SELECT o.itemId, o.selectionGeneration, 'folder', fs.folderId
            FROM offlineItems o JOIN folderItemMemberships fm ON fm.vaultId = o.vaultId AND fm.itemId = o.itemId
            JOIN folderAncestors fa ON fa.vaultId = fm.vaultId AND fa.folderId = fm.folderId
            JOIN offlineFolders fs ON fs.vaultId = fa.vaultId AND fs.folderId = fa.ancestorId
            WHERE o.vaultId = ? AND (? IS NULL OR o.itemId = ?) AND o.isManuallySelected = 0
              AND NOT EXISTS(SELECT 1 FROM offlineItemExclusions x WHERE x.vaultId = o.vaultId AND x.itemId = o.itemId)
            """, arguments: [vaultID, itemID, itemID, vaultID, itemID, itemID])
    }
}
