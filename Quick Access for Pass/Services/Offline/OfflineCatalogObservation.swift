import Foundation
import GRDB

/// Native GRDB observation that projects committed offline metadata without reading payload bytes.
nonisolated struct OfflineCatalogObservation: OfflineCatalogObserving, Sendable {
    private let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
    }

    func snapshots() -> AsyncThrowingStream<OfflinePresentationSnapshot, Error> {
        let database = database
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let pump = Task {
                do {
                    let observation = ValueObservation.tracking { db in
                        try Self.presentation(in: db)
                    }
                    for try await value in observation.values(
                        in: database.reader,
                        bufferingPolicy: .bufferingNewest(1)
                    ) {
                        try Task.checkCancellation()
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    /// Reads every presentation field in one connection. The payload is tested only by
    /// existence, schema/revision metadata, and length; it is never selected or decoded.
    static func presentation(in db: Database) throws -> OfflinePresentationSnapshot {
        let selectedVaultIDs = Set(try String.fetchAll(db, sql: "SELECT vaultId FROM offlineVaults"))
        let vaultMetadata = try Row.fetchAll(db, sql: "SELECT id, name FROM vaults")
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT o.itemId, o.vaultId, i.title, i.itemType, o.cacheStatus,
                   o.lastRefreshedAt, o.pendingRequestId, o.isManuallySelected,
                   o.selectionGeneration, vsel.policyGeneration,
                   EXISTS(SELECT 1 FROM offlineItemExclusions x WHERE x.itemId = o.itemId AND x.vaultId = o.vaultId) AS isExcluded,
                   EXISTS(
                       SELECT 1 FROM offlineSnapshots s
                       WHERE s.vaultId = o.vaultId AND s.itemId = o.itemId
                         AND s.schemaVersion = ?
                         AND length(s.snapshotRevision) = 36
                         AND length(s.keyFingerprint) = 32
                         AND length(s.encryptedPayload) BETWEEN 28 AND ?
                         AND o.cacheStatus IN (?, ?)
                   ) AS hasUsableSnapshot
            FROM offlineItems o
            JOIN items i ON i.id = o.itemId AND i.vaultId = o.vaultId
            JOIN vaults v ON v.id = o.vaultId
            LEFT JOIN offlineVaults vsel ON vsel.vaultId = o.vaultId
            WHERE i.state = 'Active'
              AND (o.isManuallySelected = 1 OR
                   (vsel.vaultId IS NOT NULL AND NOT EXISTS(
                       SELECT 1 FROM offlineItemExclusions x
                       WHERE x.itemId = o.itemId AND x.vaultId = o.vaultId
                   )))
            """,
            arguments: [
                OfflineSnapshotLimits.schemaVersion,
                OfflineSnapshotLimits.ciphertextBytes,
                OfflineCacheStatus.cached.rawValue,
                OfflineCacheStatus.failed.rawValue
            ]
        )

        var itemRows: [(row: OfflineItemSettingsRow, isProvisional: Bool)] = []
        var availabilityByItemID: [String: OfflineItemAvailability] = [:]
        var policyByItemID: [String: OfflineItemPolicy] = [:]
        for row in rows {
            guard let itemID: String = row["itemId"],
                  let vaultID: String = row["vaultId"],
                  let title: String = row["title"],
                  let itemTypeRaw: String = row["itemType"],
                  let itemType = ItemType(rawValue: itemTypeRaw),
                  let statusRaw: String = row["cacheStatus"],
                  let status = OfflineCacheStatus(rawValue: statusRaw) else {
                continue
            }
            guard let item = try PassItem.fetchOne(db, key: itemID) else { continue }
            let refreshedAt: Date? = row["lastRefreshedAt"]
            let pendingRequestID: String? = row["pendingRequestId"]
            let isManuallySelected: Bool = row["isManuallySelected"]
            let selectionGenerationRaw: String? = row["selectionGeneration"]
            let hasValidSelectionGeneration = selectionGenerationRaw.flatMap(UUID.init(uuidString:)) != nil
            let policyGenerationRaw: String? = row["policyGeneration"]
            let policyGeneration = policyGenerationRaw.flatMap(UUID.init(uuidString:))
            let isExcluded: Bool = row["isExcluded"]
            let hasUsableSnapshot: Bool = row["hasUsableSnapshot"]
            guard hasValidSelectionGeneration else { continue }
            let key = OfflineSnapshotKey(
                vaultId: vaultID, itemId: itemID, schemaVersion: OfflineSnapshotLimits.schemaVersion
            )
            policyByItemID[itemID] = OfflineItemPolicy(
                key: key,
                isManuallySelected: isManuallySelected,
                vaultSelection: policyGeneration.map { OfflineVaultSelection(vaultID: vaultID, generation: $0) },
                isExcluded: isExcluded
            )
            let availability: OfflineItemAvailability
            switch status {
            case .cached where hasUsableSnapshot:
                availability = .available(lastRefreshedAt: refreshedAt)
            case .failed where hasUsableSnapshot:
                availability = .stale(lastRefreshedAt: refreshedAt)
            case .notCached:
                availability = .notCached
            case .cached, .failed, .unavailable:
                availability = .unavailable
            }
            availabilityByItemID[itemID] = availability
            let isProvisional = status == .notCached && !hasUsableSnapshot && pendingRequestID != nil
            itemRows.append((
                OfflineItemSettingsRow(
                    itemId: itemID,
                    vaultId: vaultID,
                    title: title,
                    itemType: itemType,
                    status: status,
                    lastRefreshedAt: refreshedAt,
                    hasUsableSnapshot: hasUsableSnapshot,
                    item: item
                ),
                isProvisional
            ))
        }

        let namesByID = Dictionary(uniqueKeysWithValues: vaultMetadata.compactMap { row -> (String, String)? in
            guard let id: String = row["id"], let name: String = row["name"] else { return nil }
            return (id, name)
        })
        let displayRows = itemRows.filter { !$0.isProvisional }
        let grouped = Dictionary(grouping: displayRows, by: { $0.row.vaultId })
        var itemGroups: [OfflineItemSettingsGroup] = []
        for (vaultID, groupedRows) in grouped {
            guard let vaultName = namesByID[vaultID] else { continue }
            let items = groupedRows.map(\.row).sorted(by: Self.ordersItems)
            itemGroups.append(OfflineItemSettingsGroup(vaultId: vaultID, vaultName: vaultName, items: items))
        }
        itemGroups.sort(by: Self.ordersGroups)

        var vaults: [OfflineVaultSettingsRow] = []
        for row in vaultMetadata {
            guard let id: String = row["id"], let vaultName: String = row["name"] else { continue }
            let items = grouped[id]?.map(\.row) ?? []
            vaults.append(OfflineVaultSettingsRow(
                id: id,
                vaultName: vaultName,
                isSelected: selectedVaultIDs.contains(id),
                selectedCount: items.count,
                usableCount: items.filter(\.hasUsableSnapshot).count,
                lastRefreshedAt: items.compactMap(\.lastRefreshedAt).max()
            ))
        }
        vaults.sort(by: Self.ordersVaults)

        return OfflinePresentationSnapshot(
            vaults: vaults,
            itemGroups: itemGroups,
            selectedVaultIDs: selectedVaultIDs,
            policyByItemID: policyByItemID,
            availabilityByItemID: availabilityByItemID
        )
    }

    private static func ordersItems(_ lhs: OfflineItemSettingsRow, _ rhs: OfflineItemSettingsRow) -> Bool {
        lhs.title == rhs.title
            ? lhs.itemId < rhs.itemId
            : lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    private static func ordersGroups(_ lhs: OfflineItemSettingsGroup, _ rhs: OfflineItemSettingsGroup) -> Bool {
        lhs.vaultName == rhs.vaultName
            ? lhs.vaultId < rhs.vaultId
            : lhs.vaultName.localizedCaseInsensitiveCompare(rhs.vaultName) == .orderedAscending
    }

    private static func ordersVaults(_ lhs: OfflineVaultSettingsRow, _ rhs: OfflineVaultSettingsRow) -> Bool {
        lhs.vaultName == rhs.vaultName
            ? lhs.id < rhs.id
            : lhs.vaultName.localizedCaseInsensitiveCompare(rhs.vaultName) == .orderedAscending
    }
}
