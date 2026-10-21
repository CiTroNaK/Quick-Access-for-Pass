import Foundation
import GRDB

// MARK: - Offline Catalog Reads

nonisolated extension DatabaseManager {
    func offlineVaultIds() throws -> Set<String> {
        try reader.read { db in Set(try String.fetchAll(db, sql: "SELECT vaultId FROM offlineVaults")) }
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
}
