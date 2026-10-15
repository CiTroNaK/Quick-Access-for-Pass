import Foundation
import GRDB

nonisolated extension DatabaseManager {
    static func registerIncrementalOfflineMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v15") { db in
            try db.alter(table: "offlineItems") { table in
                table.add(column: "metadataGeneration", .text).notNull().defaults(to: "")
                table.add(column: "requestGeneration", .text).notNull().defaults(to: "")
            }
            try db.alter(table: "offlineSnapshots") { table in
                table.add(column: "sourceModifyTime", .datetime)
                table.add(column: "metadataGeneration", .text)
            }
            try initializeOfflineOwnership(in: db)
            try createOfflineSyncCaptureTables(in: db)
        }
    }

    /// Initializes non-secret ownership only; never reads snapshot payloads or snapshot keys.
    private static func initializeOfflineOwnership(in db: Database) throws {
        let selections = try Row.fetchAll(db, sql: "SELECT itemId, vaultId FROM offlineItems")
        for selection in selections {
            let itemID: String = selection["itemId"]
            let vaultID: String = selection["vaultId"]
            try db.execute(
                sql: "UPDATE offlineItems SET metadataGeneration = ?, requestGeneration = ? WHERE itemId = ? AND vaultId = ?",
                arguments: [UUID().uuidString, UUID().uuidString, itemID, vaultID]
            )
        }
    }

    private static func createOfflineSyncCaptureTables(in db: Database) throws {
        // Child rows reference only their capture. Catalog deletion must not erase admission evidence.
        try db.execute(sql: """
            CREATE TABLE offlineSyncCaptures (
                id TEXT NOT NULL PRIMARY KEY,
                syncOperationID TEXT NOT NULL,
                lifecycleGeneration TEXT NOT NULL
            );
            CREATE TABLE offlineSyncCaptureVaults (
                captureID TEXT NOT NULL REFERENCES offlineSyncCaptures(id) ON DELETE CASCADE,
                vaultID TEXT NOT NULL,
                policyGeneration TEXT NOT NULL,
                PRIMARY KEY(captureID, vaultID)
            );
            CREATE TABLE offlineSyncCaptureItems (
                captureID TEXT NOT NULL REFERENCES offlineSyncCaptures(id) ON DELETE CASCADE,
                vaultID TEXT NOT NULL,
                itemID TEXT NOT NULL,
                selectionGeneration TEXT,
                requestGeneration TEXT,
                pendingRequestID TEXT,
                isManuallySelected BOOLEAN NOT NULL CHECK(isManuallySelected IN (0, 1)),
                isExcluded BOOLEAN NOT NULL CHECK(isExcluded IN (0, 1)),
                wasEligibleForVaultSelection BOOLEAN NOT NULL CHECK(wasEligibleForVaultSelection IN (0, 1)),
                PRIMARY KEY(captureID, vaultID, itemID),
                CHECK((selectionGeneration IS NULL AND requestGeneration IS NULL AND pendingRequestID IS NULL)
                    OR (selectionGeneration IS NOT NULL AND requestGeneration IS NOT NULL))
            );
            """)
    }
}
