import Foundation
import GRDB

/// Non-secret result of the atomic metadata synchronization transaction.
nonisolated struct MetadataSynchronizationResult: Sendable {
    let descriptors: [AutoFillCredentialDescriptor]
    let didDeleteOfflineData: Bool
    let offlineMetadataProofs: [OfflineSnapshotKey: OfflineSyncedMetadataProof]
}

// MARK: - Vault Operations

nonisolated extension DatabaseManager {
    func upsertVaults(_ vaults: [PassVault]) throws {
        try writeOfflineMutation(submissionScope: .none) { db in
            let changed = try Self.writeChangedVaults(vaults, in: db)
            try Self.advanceOfflineMetadataGenerations(itemIDs: changed, in: db)
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
            let existing = Dictionary(uniqueKeysWithValues: try PassItem.fetchAll(db).map { ($0.id, $0) })
            let changed = try Self.writeChangedItems(items, existing: existing, in: db)
            try Self.advanceOfflineMetadataGenerations(itemIDs: changed, in: db)
            return OfflineMutationUpdate(value: (), manualPromotions: [])
        }
    }

    /// Replace all items with the given set (removes items not in the list).
    func syncItems(_ items: [PassItem]) throws {
        try writeOfflineMutation(submissionScope: .replaceItems(Self.offlineIncomingIdentities(items))) { db in
            let changed = try Self.syncItems(items, in: db)
            try Self.advanceOfflineMetadataGenerations(itemIDs: changed, in: db)
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
        presenceUncertainties: [SyncItemPresenceUncertainty] = [],
        operation: SyncOperationToken? = nil,
        beforeDescriptorWrite: @escaping @Sendable () throws -> Void = {}
    ) async throws -> MetadataSynchronizationResult {
        let scope = OfflineReleaseMutationScope.replaceMetadata(OfflineMetadataReplacement(
            vaultIDs: Set(vaults.map(\.id)), itemsByID: Self.offlineIncomingIdentities(items),
            presenceUncertainties: presenceUncertainties))
        return try await writeOfflineMutation(submissionScope: scope) { db in
            // Writer-transaction admission, not a pre-await freshness check.
            // Once admitted, this transaction finishes before any replacement
            // writer can commit. Never hold the authority mutex across SQL.
            if let operation, !operation.isCurrent { throw CancellationError() }
            let value = try Self.writeSyncedMetadata(
                vaults: vaults, items: items, descriptors: descriptors,
                presenceUncertainties: presenceUncertainties, operationID: operation?.id,
                beforeDescriptorWrite: beforeDescriptorWrite, in: db
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
        operationID: UUID? = nil,
        beforeDescriptorWrite: @Sendable () throws -> Void = {},
        in db: Database
    ) throws -> MetadataSynchronizationResult {
        // Counts and source comparisons stay in the committing transaction.
        let offlineSelectionsBefore = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineItems") ?? 0
        let existingItems = Dictionary(uniqueKeysWithValues: try PassItem.fetchAll(db).map { ($0.id, $0) })
        var changed = try writeChangedVaults(vaults, in: db)
        let incomingVaultIDs = Set(vaults.map(\.id))
        let retainedItemIDs = retainedUndecodedItemIDs(
            presenceUncertainties: presenceUncertainties, enumeratedVaultIDs: incomingVaultIDs, existing: existingItems
        )
        changed.formUnion(try syncItems(items, retainingAbsentIDs: retainedItemIDs, existing: existingItems, in: db))
        try pruneInvalidOfflineSelections(in: db)
        try beforeDescriptorWrite()
        changed.formUnion(try syncAutoFillDescriptors(descriptors, in: db))
        let existingVaultIDs = try String.fetchAll(db, sql: "SELECT id FROM vaults")
        let staleVaultIDs = existingVaultIDs.filter { !incomingVaultIDs.contains($0) }
        if !staleVaultIDs.isEmpty {
            try PassVault.filter(staleVaultIDs.contains(Column("id"))).deleteAll(db)
        }
        try advanceOfflineMetadataGenerations(itemIDs: changed, in: db)
        let storedDescriptors = try AutoFillCredentialDescriptor
            .order(Column("serviceIdentifier").asc, Column("vaultID").asc, Column("itemID").asc, Column("username").asc)
            .fetchAll(db)
        let offlineSelectionsAfter = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineItems") ?? 0
        return MetadataSynchronizationResult(
            descriptors: storedDescriptors,
            didDeleteOfflineData: offlineSelectionsAfter < offlineSelectionsBefore,
            offlineMetadataProofs: try offlineMetadataProofs(
                items: items, vaults: vaults, descriptors: descriptors, operationID: operationID, in: db
            )
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
        presenceUncertainties: [SyncItemPresenceUncertainty], enumeratedVaultIDs: Set<String>, existing: [String: PassItem]
    ) -> Set<String> {
        let byVault = Dictionary(grouping: existing.values, by: \.vaultId)
        var retainedIDs: Set<String> = []
        for uncertainty in presenceUncertainties where enumeratedVaultIDs.contains(uncertainty.vaultID) {
            let priorIDs = (byVault[uncertainty.vaultID] ?? []).map(\.id)
            retainedIDs.formUnion(priorIDs.filter { uncertainty.hasUnidentifiedSkippedItems || uncertainty.skippedItemIDs.contains($0) })
        }
        return retainedIDs
    }

    private static func syncItems(
        _ items: [PassItem], retainingAbsentIDs: Set<String> = [], existing: [String: PassItem]? = nil, in db: Database
    ) throws -> Set<String> {
        let prior: [String: PassItem]
        if let existing {
            prior = existing
        } else {
            prior = Dictionary(uniqueKeysWithValues: try PassItem.fetchAll(db).map { ($0.id, $0) })
        }
        let incomingIDs = Set(items.map(\.id))
        let staleIDs = prior.keys.filter { !incomingIDs.contains($0) && !retainingAbsentIDs.contains($0) }
        if !staleIDs.isEmpty {
            try PassItem.filter(staleIDs.contains(Column("id"))).deleteAll(db)
        }
        return try writeChangedItems(items, existing: prior, in: db)
    }

    private static func syncAutoFillDescriptors(
        _ inputs: [AutoFillDescriptorInput],
        in db: Database
    ) throws -> Set<String> {
        var changed: Set<String> = []
        var distinctInputs: [AutoFillDescriptorIdentityKey: AutoFillDescriptorInput] = [:]
        for input in inputs {
            distinctInputs[input.identityKey] = input
        }

        let existingDescriptors = try AutoFillCredentialDescriptor.fetchAll(db)
        let existingByKey = Dictionary(
            uniqueKeysWithValues: existingDescriptors.map { ($0.identityKey, $0) }
        )

        for input in distinctInputs.values {
            if existingByKey[input.identityKey]?.sourceInput == input { continue }
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
            if existingByKey[input.identityKey] == nil {
                try descriptor.insert(db)
            } else {
                try descriptor.update(db)
            }
            changed.insert(input.itemID)
        }

        for descriptor in existingDescriptors where distinctInputs[descriptor.identityKey] == nil {
            _ = try descriptor.delete(db)
            changed.insert(descriptor.itemID)
        }
        return changed
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
