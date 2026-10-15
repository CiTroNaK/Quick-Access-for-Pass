import Foundation
import GRDB
@testable import Quick_Access_for_Pass

/// Only persisted non-secret freshness/ownership and descriptor identities; no payload selection.
nonisolated struct IncrementalPoolStoredState: Sendable, Equatable {
    struct Item: Sendable, Equatable {
        let id: String
        let selectionGeneration: String
        let requestGeneration: String
        let metadataGeneration: String
        let snapshotMetadataGeneration: String?
        let revision: String
        let refreshedAt: Date?
        let sourceTime: Date?
    }
    let items: [Item]
    let descriptorIDs: [String: UUID]

    static func load(from database: DatabaseManager) async throws -> Self {
        try await database.reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT o.itemId, o.selectionGeneration, o.requestGeneration, o.metadataGeneration,
                       s.metadataGeneration AS snapshotMetadataGeneration, s.snapshotRevision,
                       o.lastRefreshedAt, s.sourceModifyTime
                FROM offlineItems o JOIN offlineSnapshots s ON s.itemId = o.itemId AND s.vaultId = o.vaultId
                ORDER BY o.itemId
                """)
            let items = rows.map { row in
                Item(id: row["itemId"], selectionGeneration: row["selectionGeneration"], requestGeneration: row["requestGeneration"],
                     metadataGeneration: row["metadataGeneration"], snapshotMetadataGeneration: row["snapshotMetadataGeneration"],
                     revision: row["snapshotRevision"], refreshedAt: row["lastRefreshedAt"], sourceTime: row["sourceModifyTime"])
            }
            let descriptors = try Row.fetchAll(db, sql: "SELECT itemId, id FROM autoFillDescriptors")
            return Self(items: items, descriptorIDs: Dictionary(uniqueKeysWithValues: descriptors.map { ($0["itemId"] as String, $0["id"] as UUID) }))
        }
    }
}
