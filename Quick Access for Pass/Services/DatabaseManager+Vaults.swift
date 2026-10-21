import Foundation
import GRDB

/// Non-secret result of the atomic metadata synchronization transaction.
nonisolated struct MetadataSynchronizationResult: Sendable {
    let descriptors: [AutoFillCredentialDescriptor]
    let didDeleteOfflineData: Bool
}

// MARK: - Vault Operations

nonisolated extension DatabaseManager {
    func upsertVaults(_ vaults: [PassVault]) throws {
        try writeOfflineMutation(submissionScope: .none) { db in
            for vault in vaults {
                try db.execute(
                    sql: """
                    INSERT INTO vaults (id, name, shareId) VALUES (?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        shareId = excluded.shareId
                    """,
                    arguments: [vault.id, vault.name, vault.shareId]
                )
            }
            return OfflineMutationUpdate(value: (), manualPromotions: [])
        }
    }

    func removeVaultsNotIn(_ vaultIds: Set<String>) throws {
        try writeOfflineMutation(submissionScope: .retainVaults(vaultIds)) { db in
            let existingIds = try String.fetchAll(db, sql: "SELECT id FROM vaults")
            let staleIds = existingIds.filter { !vaultIds.contains($0) }
            if !staleIds.isEmpty {
                try PassVault.filter(staleIds.contains(Column("id"))).deleteAll(db)
            }
            return OfflineMutationUpdate(value: (), manualPromotions: [])
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
    private static func offlineIncomingIdentities(_ items: [PassItem]) -> [String: OfflineIncomingItemIdentity] {
        Dictionary(items.map { item in
            (item.id, OfflineIncomingItemIdentity(vaultID: item.vaultId, itemType: item.itemType, isActive: item.state == "Active"))
        }, uniquingKeysWith: { _, newest in newest })
    }

    func upsertItems(_ items: [PassItem]) throws {
        try writeOfflineMutation(submissionScope: .upsertItems(Self.offlineIncomingIdentities(items))) { db in
            for var item in items {
                if let existing = try PassItem.fetchOne(db, key: item.id) {
                    item.useCount = existing.useCount
                    item.lastUsedAt = existing.lastUsedAt
                }
                try item.save(db)
            }
            return OfflineMutationUpdate(value: (), manualPromotions: [])
        }
    }

    /// Replace all items with the given set (removes items not in the list).
    func syncItems(_ items: [PassItem]) throws {
        try writeOfflineMutation(submissionScope: .replaceItems(Self.offlineIncomingIdentities(items))) { db in
            try Self.syncItems(items, in: db)
            return OfflineMutationUpdate(value: (), manualPromotions: [])
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
        presenceUncertainties: [SyncItemPresenceUncertainty] = [],
        beforeDescriptorWrite: @escaping @Sendable () throws -> Void = {}
    ) throws -> [AutoFillCredentialDescriptor] {
        let scope = OfflineReleaseMutationScope.replaceMetadata(OfflineMetadataReplacement(
            vaultIDs: Set(vaults.map(\.id)), itemsByID: Self.offlineIncomingIdentities(items),
            presenceUncertainties: presenceUncertainties))
        return try writeOfflineMutation(submissionScope: scope) { db in
            let value = try Self.writeSyncedMetadata(
                vaults: vaults,
                items: items,
                descriptors: descriptors,
                presenceUncertainties: presenceUncertainties,
                beforeDescriptorWrite: beforeDescriptorWrite,
                in: db
            ).descriptors
            return OfflineMutationUpdate(value: value, manualPromotions: [])
        }
    }

    /// Asynchronously writes metadata in one transaction for async sync callers.
    func synchronizeMetadata(
        vaults: [PassVault],
        items: [PassItem],
        descriptors: [AutoFillDescriptorInput],
        presenceUncertainties: [SyncItemPresenceUncertainty] = []
    ) async throws -> MetadataSynchronizationResult {
        let scope = OfflineReleaseMutationScope.replaceMetadata(OfflineMetadataReplacement(
            vaultIDs: Set(vaults.map(\.id)), itemsByID: Self.offlineIncomingIdentities(items),
            presenceUncertainties: presenceUncertainties))
        return try await writeOfflineMutation(submissionScope: scope) { db in
            let value = try Self.writeSyncedMetadata(
                vaults: vaults, items: items, descriptors: descriptors,
                presenceUncertainties: presenceUncertainties, in: db
            )
            return OfflineMutationUpdate(value: value, manualPromotions: [])
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

    private static func writeSyncedMetadata(
        vaults: [PassVault],
        items: [PassItem],
        descriptors: [AutoFillDescriptorInput],
        presenceUncertainties: [SyncItemPresenceUncertainty] = [],
        beforeDescriptorWrite: @Sendable () throws -> Void = {},
        in db: Database
    ) throws -> MetadataSynchronizationResult {
        // `syncItems` and stale-vault removal can cascade selections before the
        // explicit prune. Counts stay metadata-only and are read in this one
        // transaction so a rollback cannot request maintenance.
        let offlineSelectionsBefore = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineItems") ?? 0

        for vault in vaults {
            try db.execute(
                sql: """
                INSERT INTO vaults (id, name, shareId) VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    shareId = excluded.shareId
                """,
                arguments: [vault.id, vault.name, vault.shareId]
            )
        }

        let incomingVaultIDs = Set(vaults.map(\.id))
        let retainedItemIDs = try retainedUndecodedItemIDs(
            presenceUncertainties: presenceUncertainties, enumeratedVaultIDs: incomingVaultIDs, in: db
        )
        try syncItems(items, retainingAbsentIDs: retainedItemIDs, in: db)
        try pruneInvalidOfflineSelections(in: db)
        try beforeDescriptorWrite()
        try syncAutoFillDescriptors(descriptors, in: db)

        let existingVaultIDs = try String.fetchAll(db, sql: "SELECT id FROM vaults")
        let staleVaultIDs = existingVaultIDs.filter { !incomingVaultIDs.contains($0) }
        if !staleVaultIDs.isEmpty {
            try PassVault.filter(staleVaultIDs.contains(Column("id"))).deleteAll(db)
        }

        let descriptors = try AutoFillCredentialDescriptor
            .order(
                Column("serviceIdentifier").asc,
                Column("vaultID").asc,
                Column("itemID").asc,
                Column("username").asc
            )
            .fetchAll(db)
        let offlineSelectionsAfter = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineItems") ?? 0
        return MetadataSynchronizationResult(
            descriptors: descriptors,
            didDeleteOfflineData: offlineSelectionsAfter < offlineSelectionsBefore
        )
    }

    private static func pruneInvalidOfflineSelections(in db: Database) throws {
        try db.execute(sql: """
            DELETE FROM offlineItems
            WHERE NOT EXISTS (
                SELECT 1 FROM items
                WHERE items.id = offlineItems.itemId
                  AND items.vaultId = offlineItems.vaultId
                  AND items.state = 'Active'
            )
            OR NOT EXISTS (
                SELECT 1 FROM vaults WHERE vaults.id = offlineItems.vaultId
            )
            """)
        try db.execute(sql: """
            DELETE FROM offlineItemExclusions
            WHERE NOT EXISTS (
                SELECT 1 FROM items
                WHERE items.id = offlineItemExclusions.itemId
                  AND items.vaultId = offlineItemExclusions.vaultId
                  AND items.state = 'Active'
            )
            """)
    }

    /// Retains only existing metadata parents in successfully enumerated, incomplete
    /// vaults. This is not decoded content and must not supply descriptor inputs.
    private static func retainedUndecodedItemIDs(
        presenceUncertainties: [SyncItemPresenceUncertainty], enumeratedVaultIDs: Set<String>, in db: Database
    ) throws -> Set<String> {
        var retainedIDs: Set<String> = []
        for uncertainty in presenceUncertainties where enumeratedVaultIDs.contains(uncertainty.vaultID) {
            let priorIDs = try String.fetchAll(db, sql: "SELECT id FROM items WHERE vaultId = ?", arguments: [uncertainty.vaultID])
            retainedIDs.formUnion(priorIDs.filter { uncertainty.hasUnidentifiedSkippedItems || uncertainty.skippedItemIDs.contains($0) })
        }
        return retainedIDs
    }

    private static func syncItems(_ items: [PassItem], retainingAbsentIDs: Set<String> = [], in db: Database) throws {
        let incomingIDs = Set(items.map(\.id))
        let existingIDs = try String.fetchAll(db, sql: "SELECT id FROM items")
        let staleIDs = existingIDs.filter { !incomingIDs.contains($0) && !retainingAbsentIDs.contains($0) }
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
