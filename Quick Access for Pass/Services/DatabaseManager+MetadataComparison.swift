import Foundation
import GRDB

nonisolated extension PassItem {
    /// Persisted source projection only. Usage belongs to the host, not the incoming CLI result.
    func hasSameSourceMetadata(as other: PassItem) -> Bool {
        id == other.id && vaultId == other.vaultId && title == other.title && itemType == other.itemType
            && subtitle == other.subtitle && url == other.url && hasTOTP == other.hasTOTP && state == other.state
            && createTime.databaseValue == other.createTime.databaseValue
            && modifyTime.databaseValue == other.modifyTime.databaseValue && fieldKeys == other.fieldKeys
    }
}

nonisolated extension AutoFillCredentialDescriptor {
    var sourceInput: AutoFillDescriptorInput {
        AutoFillDescriptorInput(vaultID: vaultID, itemID: itemID, shareID: shareID, title: title,
                                username: username, serviceIdentifier: serviceIdentifier, hasTOTP: hasTOTP)
    }
}

nonisolated extension DatabaseManager {
    /// Returns selected item IDs whose share identity changed; display-only vault names do not dirty snapshots.
    static func writeChangedVaults(_ vaults: [PassVault], in db: Database) throws -> Set<String> {
        let existing = Dictionary(uniqueKeysWithValues: try PassVault.fetchAll(db).map { ($0.id, $0) })
        let incoming = Dictionary(vaults.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        var changedShares: Set<String> = []
        for vault in incoming.values {
            if let prior = existing[vault.id] {
                if prior.name == vault.name && prior.shareId == vault.shareId { continue }
                if prior.shareId != vault.shareId { changedShares.insert(vault.id) }
            }
            try db.execute(sql: """
                INSERT INTO vaults (id, name, shareId) VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, shareId = excluded.shareId
                WHERE vaults.name IS NOT excluded.name OR vaults.shareId IS NOT excluded.shareId
                """, arguments: [vault.id, vault.name, vault.shareId])
        }
        guard !changedShares.isEmpty else { return [] }
        return Set(try Row.fetchAll(db, sql: "SELECT itemId, vaultId FROM offlineItems").compactMap { row in
            changedShares.contains(row["vaultId"] as String) ? (row["itemId"] as String) : nil
        })
    }

    /// One bulk read supplies comparisons and preserves host-owned usage for all incoming items.
    static func writeChangedItems(_ items: [PassItem], existing: [String: PassItem], in db: Database) throws -> Set<String> {
        let incoming = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        var changed: Set<String> = []
        for var item in incoming.values.sorted(by: { $0.id < $1.id }) {
            if let prior = existing[item.id] {
                guard !item.hasSameSourceMetadata(as: prior) else { continue }
                item.useCount = prior.useCount
                item.lastUsedAt = prior.lastUsedAt
                try item.update(db)
            } else {
                try item.insert(db)
            }
            changed.insert(item.id)
        }
        return changed
    }

    /// Called once with the union of relevant changes, within the source transaction.
    static func advanceOfflineMetadataGenerations(itemIDs: Set<String>, in db: Database) throws {
        guard !itemIDs.isEmpty else { return }
        for row in try Row.fetchAll(db, sql: "SELECT itemId, vaultId FROM offlineItems") {
            let itemID: String = row["itemId"]
            guard itemIDs.contains(itemID) else { continue }
            let vaultID: String = row["vaultId"]
            try db.execute(sql: "UPDATE offlineItems SET metadataGeneration = ? WHERE itemId = ? AND vaultId = ?",
                           arguments: [UUID().uuidString, itemID, vaultID])
        }
    }
}
