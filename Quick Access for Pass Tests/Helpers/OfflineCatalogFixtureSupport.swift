import Foundation
import GRDB
@testable import Quick_Access_for_Pass

/// Bypasses production authorization and release-intent policy to arrange database fixtures.
nonisolated enum OfflineCatalogFixtureSupport {
    static func selectWholeVault(in database: DatabaseManager, _ vaultID: String) throws {
        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO offlineVaults (vaultId, enabledAt, policyGeneration) VALUES (?, ?, ?) ON CONFLICT(vaultId) DO NOTHING",
                           arguments: [vaultID, Date(), UUID().uuidString])
        }
    }

    static func deselectWholeVault(in database: DatabaseManager, _ vaultID: String) throws -> [OfflineItemSelection] {
        try database.writer.write { db in
            let selections = try OfflineItemSelection
                .filter(Column("vaultId") == vaultID && Column("isManuallySelected") == false)
                .order(Column("itemId").asc).fetchAll(db)
            try OfflineItemSelection.filter(Column("vaultId") == vaultID && Column("isManuallySelected") == false).deleteAll(db)
            try db.execute(sql: "DELETE FROM offlineVaults WHERE vaultId = ?", arguments: [vaultID])
            return selections
        }
    }

    static func selectManualItem(in database: DatabaseManager, itemId: String, vaultId: String) throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM offlineItemExclusions WHERE itemId = ? AND vaultId = ?", arguments: [itemId, vaultId])
            try db.execute(sql: """
                INSERT INTO offlineItems
                (itemId, vaultId, selectedAt, lastRefreshedAt, cacheStatus, pendingRequestId, isManuallySelected, selectionGeneration)
                VALUES (?, ?, ?, NULL, ?, NULL, 1, ?)
                ON CONFLICT(itemId) DO UPDATE SET isManuallySelected = 1
                """, arguments: [itemId, vaultId, Date(), OfflineCacheStatus.notCached.rawValue, UUID().uuidString])
        }
    }

    static func removeItem(in database: DatabaseManager, itemId: String) throws -> OfflineItemSelection? {
        try database.writer.write { db in
            let selection = try OfflineItemSelection.fetchOne(db, key: itemId)
            try OfflineItemSelection.deleteOne(db, key: itemId)
            return selection
        }
    }

    static func updateCacheStatus(in database: DatabaseManager, itemId: String, status: OfflineCacheStatus, refreshedAt: Date?) throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE offlineItems SET cacheStatus = ?, lastRefreshedAt = ? WHERE itemId = ?",
                           arguments: [status.rawValue, refreshedAt, itemId])
        }
    }

    static func reconcileSelections(in database: DatabaseManager, validVaultIds: Set<String>, currentVaultIDByItemID: [String: String]) throws -> [OfflineItemSelection] {
        try database.writer.write { db in
            let selections = try OfflineItemSelection.order(Column("itemId").asc).fetchAll(db)
            let stale = selections.filter { !validVaultIds.contains($0.vaultId) || currentVaultIDByItemID[$0.itemId] != $0.vaultId }
            for selection in stale { try OfflineItemSelection.filter(key: selection.itemId).deleteAll(db) }
            try db.execute(sql: """
                DELETE FROM offlineItemExclusions WHERE NOT EXISTS (
                    SELECT 1 FROM items i WHERE i.id = offlineItemExclusions.itemId
                      AND i.vaultId = offlineItemExclusions.vaultId AND i.state = 'Active'
                )
                """)
            return stale
        }
    }

    static func removeAllCatalogData(in database: DatabaseManager) throws -> [OfflineItemSelection] {
        try database.writer.write { db in
            let selections = try OfflineItemSelection.order(Column("itemId").asc).fetchAll(db)
            try OfflineItemSelection.deleteAll(db)
            try db.execute(sql: "DELETE FROM offlineVaults")
            try db.execute(sql: "DELETE FROM offlineItemExclusions")
            return selections
        }
    }
}
