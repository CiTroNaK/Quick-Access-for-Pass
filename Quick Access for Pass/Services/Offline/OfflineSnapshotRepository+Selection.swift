import Foundation
import GRDB
nonisolated extension OfflineSnapshotRepository {
    func selectItemManually(itemID: String, vaultID: String, shareID: String) async throws -> UUID {
        do {
            return try await database.writeOfflineMutation(submissionScope: .none) { db in
                guard try String.fetchOne(db, sql: "SELECT state FROM items WHERE id = ? AND vaultId = ?", arguments: [itemID, vaultID]) == "Active",
                      try String.fetchOne(db, sql: "SELECT shareId FROM vaults WHERE id = ?", arguments: [vaultID]) == shareID else {
                    throw OfflinePersistenceError.identityChanged
                }
                try db.execute(sql: "DELETE FROM offlineItemExclusions WHERE itemId = ? AND vaultId = ?", arguments: [itemID, vaultID])
                let generation: UUID
                let didPromote: Bool
                if let existing = try Row.fetchOne(db,
                    sql: "SELECT selectionGeneration, isManuallySelected FROM offlineItems WHERE itemId = ? AND vaultId = ?",
                    arguments: [itemID, vaultID]) {
                    guard let storedGeneration: String = existing["selectionGeneration"],
                          let value = UUID(uuidString: storedGeneration) else { throw OfflinePersistenceError.persistenceFailed }
                    generation = value
                    didPromote = (existing["isManuallySelected"] as Int) == 0
                    try db.execute(sql: "UPDATE offlineItems SET isManuallySelected = 1 WHERE itemId = ? AND vaultId = ?", arguments: [itemID, vaultID])
                } else {
                    generation = UUID()
                    didPromote = true
                    try db.execute(
                        sql: """
                            INSERT INTO offlineItems
                            (itemId, vaultId, selectedAt, lastRefreshedAt, cacheStatus, pendingRequestId, isManuallySelected,
                             selectionGeneration, metadataGeneration, requestGeneration)
                            VALUES (?, ?, ?, NULL, ?, NULL, 1, ?, ?, ?)
                            """,
                        arguments: [itemID, vaultID, Date(), OfflineCacheStatus.notCached.rawValue, generation.uuidString,
                                    UUID().uuidString, UUID().uuidString]
                    )
                }
                let promotions = [OfflineManualPromotion(
                    key: OfflineSnapshotKey(vaultId: vaultID, itemId: itemID, schemaVersion: OfflineSnapshotLimits.schemaVersion),
                    selectionGeneration: generation)]
                return OfflineMutationUpdate(value: generation, manualPromotions: didPromote ? promotions : [])
            }
        } catch let error as OfflinePersistenceError { throw error } catch { throw OfflinePersistenceError.persistenceFailed }
    }
    func keepItemOfflineIndividually(itemID: String, vaultID: String) async throws {
        do {
            try await database.writeOfflineMutation(submissionScope: .none) { db in
                guard try Bool.fetchOne(
                    db,
                    sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM offlineItems o
                        JOIN items i ON i.id = o.itemId AND i.vaultId = o.vaultId
                        WHERE o.itemId = ? AND o.vaultId = ? AND i.state = 'Active'
                          AND \(OfflineSelectionSQL.effectiveSelection)
                    )
                    """,
                    arguments: [itemID, vaultID]
                ) == true else {
                    throw OfflinePersistenceError.itemUnavailable
                }
                let wasManual = try Bool.fetchOne(db,
                    sql: "SELECT isManuallySelected FROM offlineItems WHERE itemId = ? AND vaultId = ?",
                    arguments: [itemID, vaultID]) == true
                try db.execute(sql: "UPDATE offlineItems SET isManuallySelected = 1 WHERE itemId = ? AND vaultId = ?", arguments: [itemID, vaultID])
                try db.execute(sql: "DELETE FROM offlineItemExclusions WHERE itemId = ? AND vaultId = ?", arguments: [itemID, vaultID])
                guard let rawGeneration = try String.fetchOne(db,
                    sql: "SELECT selectionGeneration FROM offlineItems WHERE itemId = ? AND vaultId = ?",
                    arguments: [itemID, vaultID]),
                      let generation = UUID(uuidString: rawGeneration) else { throw OfflinePersistenceError.persistenceFailed }
                let promotions = [OfflineManualPromotion(
                    key: OfflineSnapshotKey(vaultId: vaultID, itemId: itemID, schemaVersion: OfflineSnapshotLimits.schemaVersion),
                    selectionGeneration: generation)]
                return OfflineMutationUpdate(value: (), manualPromotions: wasManual ? [] : promotions)
            }
        } catch let error as OfflinePersistenceError { throw error } catch { throw OfflinePersistenceError.persistenceFailed }
    }
    func itemPolicy(itemID: String, vaultID: String) async throws -> OfflineItemPolicy? {
        do {
            return try await database.reader.read { db in
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT COALESCE(o.isManuallySelected, 0) AS isManuallySelected,
                           (SELECT policyGeneration FROM offlineVaults WHERE vaultId = i.vaultId) AS policyGeneration,
                           EXISTS(SELECT 1 FROM offlineItemExclusions x WHERE x.itemId = i.id AND x.vaultId = i.vaultId) AS isExcluded
                    FROM items i
                    LEFT JOIN offlineItems o ON o.itemId = i.id AND o.vaultId = i.vaultId
                    WHERE i.id = ? AND i.vaultId = ? AND i.state = 'Active'
                    """, arguments: [itemID, vaultID]) else { return nil }
                let generationString: String? = row["policyGeneration"]
                let generation = generationString.flatMap(UUID.init(uuidString:))
                let selected = generation.map { OfflineVaultSelection(vaultID: vaultID, generation: $0) }
                return OfflineItemPolicy(
                    key: OfflineSnapshotKey(vaultId: vaultID, itemId: itemID, schemaVersion: OfflineSnapshotLimits.schemaVersion),
                    isManuallySelected: (row["isManuallySelected"] as Int) == 1,
                    vaultSelection: selected,
                    isExcluded: (row["isExcluded"] as Int) == 1
                )
            }
        } catch { throw OfflinePersistenceError.persistenceFailed }
    }
    func workCandidateForSelectedItem(itemID: String, vaultID: String) async throws -> OfflineSnapshotWorkCandidate? {
        do {
            return try await database.reader.read { db in
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT i.id AS itemId, i.vaultId, i.modifyTime, i.itemType, v.shareId,
                           o.selectionGeneration, o.cacheStatus
                    FROM offlineItems o
                    JOIN items i ON i.id = o.itemId AND i.vaultId = o.vaultId
                    JOIN vaults v ON v.id = o.vaultId
                    WHERE o.itemId = ? AND o.vaultId = ? AND i.state = 'Active'
                      AND \(OfflineSelectionSQL.effectiveSelection)
                    """, arguments: [itemID, vaultID]) else { return nil }
                guard let currentItemID: String = row["itemId"], let currentVaultID: String = row["vaultId"],
                      let shareID: String = row["shareId"], let modifyTime: Date = row["modifyTime"],
                      let rawType: String = row["itemType"], let type = ItemType(rawValue: rawType),
                      let rawGeneration: String = row["selectionGeneration"],
                      let generation = UUID(uuidString: rawGeneration),
                      let status: String = row["cacheStatus"] else { return nil }
                let intent: OfflineSnapshotWorkIntent
                switch status {
                case OfflineCacheStatus.cached.rawValue, OfflineCacheStatus.failed.rawValue:
                    intent = .refresh(selectionGeneration: generation)
                case OfflineCacheStatus.notCached.rawValue, OfflineCacheStatus.unavailable.rawValue:
                    intent = .materialize(selectionGeneration: generation)
                default: return nil
                }
                return makeCandidate(
                    key: OfflineSnapshotKey(
                        vaultId: currentVaultID, itemId: currentItemID, schemaVersion: OfflineSnapshotLimits.schemaVersion
                    ),
                    shareID: shareID, modifyTime: modifyTime, type: type, intent: intent
                )
            }
        } catch { throw OfflinePersistenceError.persistenceFailed }
    }
    func workCandidates(vaultID: String?, includeNewSelections: Bool, refreshExisting: Bool) async throws -> [OfflineSnapshotWorkCandidate] {
        do {
            return try await database.reader.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT i.id AS itemId, i.vaultId, i.modifyTime, i.itemType, v.shareId,
                           o.selectionGeneration, o.cacheStatus,
                           vs.policyGeneration,
                           EXISTS(SELECT 1 FROM offlineItemExclusions x WHERE x.itemId = i.id AND x.vaultId = i.vaultId) AS isExcluded
                    FROM items i JOIN vaults v ON v.id = i.vaultId
                    LEFT JOIN offlineItems o ON o.itemId = i.id AND o.vaultId = i.vaultId
                    LEFT JOIN offlineVaults vs ON vs.vaultId = i.vaultId
                    WHERE i.state = 'Active' AND (? IS NULL OR i.vaultId = ?)
                    ORDER BY i.vaultId, i.id
                    """, arguments: [vaultID, vaultID])
                return rows.compactMap { row in
                    guard let itemID: String = row["itemId"], let currentVaultID: String = row["vaultId"],
                          let shareID: String = row["shareId"], let modifyTime: Date = row["modifyTime"],
                          let rawType: String = row["itemType"], let type = ItemType(rawValue: rawType) else { return nil }
                    let selectedAt: String? = row["selectionGeneration"]
                    let selectionGeneration = selectedAt.flatMap(UUID.init(uuidString:))
                    let policyGeneration = (row["policyGeneration"] as String?).flatMap(UUID.init(uuidString:))
                    let excluded = (row["isExcluded"] as Int? ?? 0) == 1
                    let cacheStatus: String? = row["cacheStatus"]
                    if let selectionGeneration {
                        let canRefresh = cacheStatus == OfflineCacheStatus.cached.rawValue
                            || cacheStatus == OfflineCacheStatus.failed.rawValue
                        if refreshExisting && canRefresh {
                            return makeCandidate(
                                key: OfflineSnapshotKey(vaultId: currentVaultID, itemId: itemID, schemaVersion: OfflineSnapshotLimits.schemaVersion),
                                shareID: shareID,
                                modifyTime: modifyTime, type: type,
                                intent: .refresh(selectionGeneration: selectionGeneration)
                            )
                        }
                        let needsMaterialization = cacheStatus == OfflineCacheStatus.notCached.rawValue
                            || cacheStatus == OfflineCacheStatus.unavailable.rawValue
                        if includeNewSelections && needsMaterialization {
                            return makeCandidate(
                                key: OfflineSnapshotKey(vaultId: currentVaultID, itemId: itemID, schemaVersion: OfflineSnapshotLimits.schemaVersion),
                                shareID: shareID,
                                modifyTime: modifyTime, type: type,
                                intent: .materialize(selectionGeneration: selectionGeneration)
                            )
                        }
                        return nil
                    }
                    guard selectedAt == nil, includeNewSelections, !excluded, let policyGeneration else { return nil }
                    return makeCandidate(
                        key: OfflineSnapshotKey(vaultId: currentVaultID, itemId: itemID, schemaVersion: OfflineSnapshotLimits.schemaVersion),
                                shareID: shareID,
                        modifyTime: modifyTime, type: type,
                        intent: .vaultMaterialize(policyGeneration: policyGeneration)
                    )
                }
            }
        } catch { throw OfflinePersistenceError.persistenceFailed }
    }
    private func makeCandidate(
        key: OfflineSnapshotKey, shareID: String, modifyTime: Date,
        type: ItemType, intent: OfflineSnapshotWorkIntent
    ) -> OfflineSnapshotWorkCandidate {
        OfflineSnapshotWorkCandidate(
            key: key,
            shareID: shareID,
            metadataModifyTime: modifyTime,
            itemType: type,
            intent: intent
        )
    }
}
