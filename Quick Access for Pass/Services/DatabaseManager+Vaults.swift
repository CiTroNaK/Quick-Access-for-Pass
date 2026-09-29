import Foundation
import GRDB

// MARK: - Vault Operations

nonisolated extension DatabaseManager {
    func upsertVaults(_ vaults: [PassVault]) throws {
        try writer.write { db in
            for vault in vaults {
                try vault.save(db, onConflict: .replace)
            }
        }
    }

    func removeVaultsNotIn(_ vaultIds: Set<String>) throws {
        try writer.write { db in
            let existingIds = try String.fetchAll(db, sql: "SELECT id FROM vaults")
            let staleIds = existingIds.filter { !vaultIds.contains($0) }
            if !staleIds.isEmpty {
                try PassVault.filter(staleIds.contains(Column("id"))).deleteAll(db)
            }
        }
    }

    func allVaults() throws -> [PassVault] {
        try reader.read { db in
            try PassVault.fetchAll(db)
        }
    }

    func vaultName(for vaultId: String) throws -> String? {
        try reader.read { db in
            try PassVault.fetchOne(db, key: vaultId)?.name
        }
    }

    func vaultShareId(for vaultId: String) throws -> String? {
        try reader.read { db in
            try PassVault.fetchOne(db, key: vaultId)?.shareId
        }
    }
}

// MARK: - Item Operations

nonisolated extension DatabaseManager {
    func upsertItems(_ items: [PassItem]) throws {
        try writer.write { db in
            for var item in items {
                if let existing = try PassItem.fetchOne(db, key: item.id) {
                    item.useCount = existing.useCount
                    item.lastUsedAt = existing.lastUsedAt
                }
                try item.save(db, onConflict: .replace)
            }
        }
    }

    /// Replace all items with the given set (removes items not in the list).
    func syncItems(_ items: [PassItem]) throws {
        try writer.write { db in
            try Self.syncItems(items, in: db)
        }
    }

    /// Atomically replaces synced vault/item metadata and its derived AutoFill descriptors.
    ///
    /// The hook runs after item writes and exists so transaction rollback can be tested
    /// deterministically without introducing invalid production metadata.
    func syncMetadata(
        vaults: [PassVault],
        items: [PassItem],
        descriptors: [AutoFillDescriptorInput],
        beforeDescriptorWrite: @Sendable () throws -> Void = {}
    ) throws -> [AutoFillCredentialDescriptor] {
        try writer.write { db in
            for vault in vaults {
                try db.execute(
                    sql: """
                        INSERT INTO vaults (id, name, shareId)
                        VALUES (?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            name = excluded.name,
                            shareId = excluded.shareId
                        """,
                    arguments: [vault.id, vault.name, vault.shareId]
                )
            }

            try Self.syncItems(items, in: db)
            try beforeDescriptorWrite()
            try Self.syncAutoFillDescriptors(descriptors, in: db)

            let incomingVaultIDs = Set(vaults.map(\.id))
            let existingVaultIDs = try String.fetchAll(db, sql: "SELECT id FROM vaults")
            let staleVaultIDs = existingVaultIDs.filter { !incomingVaultIDs.contains($0) }
            if !staleVaultIDs.isEmpty {
                try PassVault.filter(staleVaultIDs.contains(Column("id"))).deleteAll(db)
            }

            return try AutoFillCredentialDescriptor
                .order(
                    Column("serviceIdentifier").asc,
                    Column("vaultID").asc,
                    Column("itemID").asc,
                    Column("username").asc
                )
                .fetchAll(db)
        }
    }

    /// Returns every descriptor in deterministic service order.
    func allAutoFillDescriptors() throws -> [AutoFillCredentialDescriptor] {
        try reader.read { db in
            try AutoFillCredentialDescriptor
                .order(
                    Column("serviceIdentifier").asc,
                    Column("vaultID").asc,
                    Column("itemID").asc,
                    Column("username").asc
                )
                .fetchAll(db)
        }
    }

    private static func syncItems(_ items: [PassItem], in db: Database) throws {
        let incomingIDs = Set(items.map(\.id))
        let existingIDs = try String.fetchAll(db, sql: "SELECT id FROM items")
        let staleIDs = existingIDs.filter { !incomingIDs.contains($0) }
        if !staleIDs.isEmpty {
            try PassItem.filter(staleIDs.contains(Column("id"))).deleteAll(db)
        }

        for var item in items {
            if let existing = try PassItem.fetchOne(db, key: item.id) {
                item.useCount = existing.useCount
                item.lastUsedAt = existing.lastUsedAt
            }
            try item.save(db)
        }
    }

    private static func syncAutoFillDescriptors(
        _ inputs: [AutoFillDescriptorInput],
        in db: Database
    ) throws {
        var distinctInputs: [AutoFillDescriptorIdentityKey: AutoFillDescriptorInput] = [:]
        for input in inputs {
            distinctInputs[input.identityKey] = input
        }

        let existingDescriptors = try AutoFillCredentialDescriptor.fetchAll(db)
        let existingByKey = Dictionary(
            uniqueKeysWithValues: existingDescriptors.map { ($0.identityKey, $0) }
        )

        for input in distinctInputs.values {
            let descriptor = AutoFillCredentialDescriptor(
                id: existingByKey[input.identityKey]?.id ?? UUID(),
                vaultID: input.vaultID,
                itemID: input.itemID,
                shareID: input.shareID,
                title: input.title,
                username: input.username,
                serviceIdentifier: input.serviceIdentifier,
                hasTOTP: input.hasTOTP
            )
            try descriptor.save(db)
        }

        for descriptor in existingDescriptors where distinctInputs[descriptor.identityKey] == nil {
            _ = try descriptor.delete(db)
        }
    }

    func allActiveItems() throws -> [PassItem] {
        try reader.read { db in
            try PassItem
                .filter(Column("state") == "Active")
                .order(Column("useCount").desc, Column("title").asc)
                .fetchAll(db)
        }
    }

    func recordUsage(itemId: String) throws {
        try writer.write { db in
            if var item = try PassItem.fetchOne(db, key: itemId) {
                item.useCount += 1
                item.lastUsedAt = Date()
                try item.update(db)
            }
        }
    }

    func searchItems(query: String) throws -> [PassItem] {
        try reader.read { db in
            // Strip non-alphanumeric characters and FTS5 reserved keywords (AND/OR/NOT/NEAR)
            // to prevent SQLite syntax errors from user input.
            let ftsReserved: Set<String> = ["AND", "OR", "NOT", "NEAR"]
            let tokens = query
                .components(separatedBy: .alphanumerics.inverted)
                .filter { !$0.isEmpty }
            let sanitized = tokens
                .filter { !ftsReserved.contains($0.uppercased()) }
                .map { "\($0)*" }
                .joined(separator: " ")

            // Empty original query → return all active items sorted by usage.
            // Non-empty query where all terms were reserved keywords → return nothing.
            guard !sanitized.isEmpty else {
                if tokens.isEmpty {
                    return try PassItem
                        .filter(Column("state") == "Active")
                        .order(Column("useCount").desc, Column("title").asc)
                        .fetchAll(db)
                } else {
                    return []
                }
            }

            let sql = """
                SELECT items.*
                FROM items
                JOIN items_ft ON items_ft.rowid = items.rowid
                    AND items_ft MATCH ?
                WHERE items.state = 'Active'
                ORDER BY
                    items.useCount DESC,
                    rank,
                    items.title ASC
                """
            return try PassItem.fetchAll(db, sql: sql, arguments: [sanitized])
        }
    }
}
