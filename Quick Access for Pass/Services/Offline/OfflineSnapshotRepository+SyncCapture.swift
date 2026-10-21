import Foundation
import GRDB

nonisolated extension OfflineSnapshotRepository {
    /// Reserve metadata-only authority before the caller starts its sync fetch.
    func beginSyncCapture(operation: SyncOperationToken, lifecycleGeneration: UUID) async throws -> OfflineSyncCapture {
        try Task.checkCancellation()
        return try await database.writer.write { db in
            guard operation.isCurrent else { throw OfflinePersistenceError.identityChanged }
            let capture = OfflineSyncCapture(id: UUID(), operation: operation, lifecycleGeneration: lifecycleGeneration)
            try db.execute(sql: "INSERT INTO offlineSyncCaptures (id, syncOperationID, lifecycleGeneration) VALUES (?, ?, ?)",
                           arguments: [capture.id.uuidString, operation.id.uuidString, lifecycleGeneration.uuidString])
            try db.execute(sql: """
                INSERT INTO offlineSyncCaptureVaults (captureID, vaultID, policyGeneration)
                SELECT ?, vaultId, policyGeneration FROM offlineVaults
                """, arguments: [capture.id.uuidString])
            try db.execute(sql: Self.captureKnownItemsSQL, arguments: [capture.id.uuidString])
            return capture
        }
    }

    /// Ending an obsolete operation is permitted, but cannot delete a successor's capture.
    func endSyncCapture(_ capture: OfflineSyncCapture) async throws {
        try await database.writer.write { db in
            try db.execute(sql: """
                DELETE FROM offlineSyncCaptures WHERE id = ? AND syncOperationID = ? AND lifecycleGeneration = ?
                """, arguments: [capture.id.uuidString, capture.operation.id.uuidString, capture.lifecycleGeneration.uuidString])
        }
    }

    private static var captureKnownItemsSQL: String {
        let selected = "i.state = 'Active' AND (\(OfflineSelectionSQL.effectiveSelection))"
        return """
            INSERT INTO offlineSyncCaptureItems
            (captureID, vaultID, itemID, selectionGeneration, requestGeneration, pendingRequestID,
             isManuallySelected, isExcluded, wasEligibleForVaultSelection)
            SELECT ?, i.vaultId, i.id,
                   CASE WHEN \(selected) THEN o.selectionGeneration END,
                   CASE WHEN \(selected) THEN o.requestGeneration END,
                   CASE WHEN \(selected) THEN o.pendingRequestId END,
                   COALESCE(o.isManuallySelected, 0),
                   EXISTS(SELECT 1 FROM offlineItemExclusions x WHERE x.itemId = i.id AND x.vaultId = i.vaultId),
                   i.state = 'Active'
                     AND EXISTS(SELECT 1 FROM offlineVaults p WHERE p.vaultId = i.vaultId)
                     AND NOT EXISTS(SELECT 1 FROM offlineItemExclusions x WHERE x.itemId = i.id AND x.vaultId = i.vaultId)
            FROM items i LEFT JOIN offlineItems o ON o.itemId = i.id AND o.vaultId = i.vaultId
            """
    }
}
