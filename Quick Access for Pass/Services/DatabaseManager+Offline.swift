import Foundation
import GRDB

nonisolated enum OfflineCatalogError: Error, Equatable {
    case itemVaultMismatch
}

// MARK: - Offline Catalog

nonisolated extension DatabaseManager {
    func selectWholeOfflineVault(_ vaultID: String) throws {
        try writer.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM vaults WHERE id = ?)", arguments: [vaultID]) == true else {
                throw OfflineCatalogError.itemVaultMismatch
            }
            try db.execute(
                sql: "INSERT INTO offlineVaults (vaultId, enabledAt, policyGeneration) VALUES (?, ?, ?) ON CONFLICT(vaultId) DO NOTHING",
                arguments: [vaultID, Date(), UUID().uuidString]
            )
        }
    }

    func deselectWholeOfflineVault(_ vaultID: String) throws -> [OfflineItemSelection] {
        try writer.write { db in
            let selections = try OfflineItemSelection
                .filter(Column("vaultId") == vaultID && Column("isManuallySelected") == false)
                .order(Column("itemId").asc)
                .fetchAll(db)
            try OfflineItemSelection
                .filter(Column("vaultId") == vaultID && Column("isManuallySelected") == false)
                .deleteAll(db)
            try db.execute(sql: "DELETE FROM offlineVaults WHERE vaultId = ?", arguments: [vaultID])
            return selections
        }
    }

    func offlineVaultIds() throws -> Set<String> {
        try reader.read { db in Set(try String.fetchAll(db, sql: "SELECT vaultId FROM offlineVaults")) }
    }

    func selectManualOfflineItem(itemId: String, vaultId: String) throws {
        try writer.write { db in
            guard try String.fetchOne(db, sql: "SELECT vaultId FROM items WHERE id = ? AND state = 'Active'", arguments: [itemId]) == vaultId else {
                throw OfflineCatalogError.itemVaultMismatch
            }
            try db.execute(sql: "DELETE FROM offlineItemExclusions WHERE itemId = ? AND vaultId = ?", arguments: [itemId, vaultId])
            try db.execute(sql: """
                INSERT INTO offlineItems
                (itemId, vaultId, selectedAt, lastRefreshedAt, cacheStatus, pendingRequestId, isManuallySelected, selectionGeneration)
                VALUES (?, ?, ?, NULL, ?, NULL, 1, ?)
                ON CONFLICT(itemId) DO UPDATE SET isManuallySelected = 1
                """, arguments: [itemId, vaultId, Date(), OfflineCacheStatus.notCached.rawValue, UUID().uuidString])
        }
    }

    func removeOfflineItem(itemId: String) throws -> OfflineItemSelection? {
        try writer.write { db in
            let selection = try OfflineItemSelection.fetchOne(db, key: itemId)
            _ = try OfflineItemSelection.deleteOne(db, key: itemId)
            return selection
        }
    }

    func offlineItemSelection(itemId: String) throws -> OfflineItemSelection? {
        try reader.read { db in
            try OfflineItemSelection.fetchOne(db, sql: """
                SELECT o.* FROM offlineItems o
                JOIN items i ON i.id = o.itemId AND i.vaultId = o.vaultId
                WHERE o.itemId = ? AND i.state = 'Active'
                  AND \(OfflineSelectionSQL.effectiveSelection)
                """, arguments: [itemId])
        }
    }

    func offlineItemSelections() throws -> [OfflineItemSelection] {
        try reader.read { db in
            try OfflineItemSelection.order(Column("itemId").asc).fetchAll(db)
        }
    }

    func updateOfflineCacheStatus(itemId: String, status: OfflineCacheStatus, refreshedAt: Date?) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE offlineItems SET cacheStatus = ?, lastRefreshedAt = ? WHERE itemId = ?", arguments: [status.rawValue, refreshedAt, itemId])
        }
    }

    func reconcileOfflineSelections(validVaultIds: Set<String>, currentVaultIDByItemID: [String: String]) throws -> [OfflineItemSelection] {
        try writer.write { db in
            let selections = try OfflineItemSelection.order(Column("itemId").asc).fetchAll(db)
            let stale = selections.filter { !validVaultIds.contains($0.vaultId) || currentVaultIDByItemID[$0.itemId] != $0.vaultId }
            for selection in stale {
                try OfflineItemSelection.filter(key: selection.itemId).deleteAll(db)
            }
            try db.execute(sql: """
                DELETE FROM offlineItemExclusions
                WHERE NOT EXISTS (
                    SELECT 1 FROM items i WHERE i.id = offlineItemExclusions.itemId
                      AND i.vaultId = offlineItemExclusions.vaultId AND i.state = 'Active'
                )
                """)
            return stale
        }
    }

    func removeAllOfflineCatalogData() throws -> [OfflineItemSelection] {
        try writer.write { db in
            let selections = try OfflineItemSelection.order(Column("itemId").asc).fetchAll(db)
            try OfflineItemSelection.deleteAll(db)
            try db.execute(sql: "DELETE FROM offlineVaults")
            try db.execute(sql: "DELETE FROM offlineItemExclusions")
            return selections
        }
    }
}
