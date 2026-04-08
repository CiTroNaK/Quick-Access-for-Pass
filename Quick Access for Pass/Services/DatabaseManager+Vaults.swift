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
            // Build a set of incoming IDs for O(1) lookup
            let incomingIds = Set(items.map(\.id))

            // Fetch IDs of all existing items and delete those not in the incoming set.
            // This avoids an unbounded NOT IN(...) SQL clause by using an IN(...) with stale IDs instead.
            let existingIds = try String.fetchAll(db, sql: "SELECT id FROM items")
            let staleIds = existingIds.filter { !incomingIds.contains($0) }
            if !staleIds.isEmpty {
                try PassItem.filter(staleIds.contains(Column("id"))).deleteAll(db)
            }

            for var item in items {
                if let existing = try PassItem.fetchOne(db, key: item.id) {
                    item.useCount = existing.useCount
                    item.lastUsedAt = existing.lastUsedAt
                }
                try item.save(db, onConflict: .replace)
            }
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
