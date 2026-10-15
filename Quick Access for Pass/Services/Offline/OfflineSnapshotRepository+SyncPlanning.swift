import Foundation
import GRDB

nonisolated extension OfflineSnapshotRepository {
    func syncWork(
        capture: OfflineSyncCapture,
        metadataProofs: [OfflineSnapshotKey: OfflineSyncedMetadataProof],
        sourceTimes: [String: Date],
        allowMembershipExpansion: Bool
    ) async throws -> [OfflineSyncWork] {
        try Task.checkCancellation()
        guard capture.operation.isCurrent else { return [] }
        // Small fallback rechecks project only requested IDs, retaining all captured vault evidence
        // for each ID. Large initial planning keeps constant bindings rather than an unbounded IN list.
        let itemIDs: Set<String>? = metadataProofs.count <= OfflineSyncPublicationLimits.items ? Set(metadataProofs.keys.map(\.itemId)) : nil
        return try await database.reader.read { db in
            try Self.syncWork(capture: capture, metadataProofs: metadataProofs, sourceTimes: sourceTimes,
                              allowMembershipExpansion: allowMembershipExpansion, itemIDs: itemIDs, in: db)
        }
    }

    /// Same persisted eligibility check for reader planning and final writer admission. Never creates a new proof.
    static func syncWork(
        capture: OfflineSyncCapture, metadataProofs: [OfflineSnapshotKey: OfflineSyncedMetadataProof],
        sourceTimes: [String: Date], allowMembershipExpansion: Bool, itemIDs: Set<String>? = nil, in db: Database
    ) throws -> [OfflineSyncWork] {
        guard capture.operation.isCurrent, itemIDs?.isEmpty != true, try hasSyncCapture(capture, in: db) else { return [] }
        let ids = itemIDs?.sorted()
        let placeholders = ids.map { Array(repeating: "?", count: $0.count).joined(separator: ",") }
        let knownFilter = placeholders.map { " AND itemID IN (\($0))" } ?? ""
        let arguments = StatementArguments([capture.id.uuidString] + (ids ?? []))
        let known = Dictionary(grouping: try Row.fetchAll(db, sql: "SELECT * FROM offlineSyncCaptureItems WHERE captureID = ?" + knownFilter,
                                                        arguments: arguments), by: { (row: Row) -> String in row["itemID"] })
        let inputs = try ids.map { try AutoFillCredentialDescriptor.filter($0.contains(Column("itemID"))).fetchAll(db) }
            ?? AutoFillCredentialDescriptor.fetchAll(db)
        let descriptors = Dictionary(grouping: inputs, by: {
            OfflineSnapshotKey(vaultId: $0.vaultID, itemId: $0.itemID, schemaVersion: OfflineSnapshotLimits.schemaVersion)
        })
        let rowFilter = placeholders.map { " AND i.id IN (\($0))" } ?? ""
        let rows = try Row.fetchAll(db, sql: syncPlanningSQL + rowFilter + " ORDER BY i.vaultId, i.id", arguments: arguments)
        let work = try rows.compactMap { raw -> OfflineSyncWork? in
            let row = try OfflineSyncPlanningRow(raw)
            guard let proof = metadataProofs[row.key], proof.operationID == capture.operation.id,
                  row.matches(proof, descriptors: descriptors[row.key] ?? []),
                  let ownership = row.ownership(known: known[row.item.id], allowExpansion: allowMembershipExpansion) else { return nil }
            let source = sourceTimes[row.item.id].flatMap { time in
                time.timeIntervalSince1970.isFinite && time == proof.item.modifyTime ? time : nil
            }
            guard !row.canSkip(source: source, proof: proof) else { return nil }
            return OfflineSyncWork(key: row.key, shareID: row.shareID, itemType: row.item.itemType,
                                   metadataProof: proof, ownership: ownership, capturedPendingRequestID: nil,
                                   expectedSourceModifyTime: source)
        }
        return capture.operation.isCurrent ? work : []
    }

    static func hasSyncCapture(_ capture: OfflineSyncCapture, in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM offlineSyncCaptures WHERE id = ? AND syncOperationID = ? AND lifecycleGeneration = ?)
            """, arguments: [capture.id.uuidString, capture.operation.id.uuidString, capture.lifecycleGeneration.uuidString]) ?? false
    }

    private static let syncPlanningSQL = """
        SELECT i.*, v.shareId AS currentShareID,
               o.itemId IS NOT NULL AS hasSelectedRow, COALESCE(o.isManuallySelected, 0) AS currentManual,
               o.selectionGeneration AS currentSelectionGeneration, o.requestGeneration AS currentRequestGeneration,
               o.metadataGeneration AS currentMetadataGeneration, o.pendingRequestId AS currentPendingRequestID,
               p.policyGeneration AS currentPolicyGeneration, c.policyGeneration AS capturedPolicyGeneration,
               EXISTS(SELECT 1 FROM offlineItemExclusions x WHERE x.itemId = i.id AND x.vaultId = i.vaultId) AS currentExcluded,
               o.cacheStatus, s.schemaVersion AS snapshotSchemaVersion, s.snapshotRevision,
               length(s.keyFingerprint) AS fingerprintLength, length(s.encryptedPayload) AS payloadLength,
               s.sourceModifyTime AS snapshotSourceTime, s.metadataGeneration AS snapshotMetadataGeneration
        FROM items i JOIN vaults v ON v.id = i.vaultId
        LEFT JOIN offlineItems o ON o.itemId = i.id AND o.vaultId = i.vaultId
        LEFT JOIN offlineVaults p ON p.vaultId = i.vaultId
        LEFT JOIN offlineSyncCaptureVaults c ON c.captureID = ? AND c.vaultID = i.vaultId
        LEFT JOIN offlineSnapshots s ON s.itemId = i.id AND s.vaultId = i.vaultId
        WHERE i.state = 'Active'
        """
}

/// All decoded values are ordinary metadata; ciphertext is never selected by the planner.
nonisolated private struct OfflineSyncPlanningRow {
    let item: PassItem
    let raw: Row
    let shareID: String
    var key: OfflineSnapshotKey { OfflineSnapshotKey(vaultId: item.vaultId, itemId: item.id, schemaVersion: OfflineSnapshotLimits.schemaVersion) }

    init(_ row: Row) throws {
        item = try PassItem(row: row)
        shareID = row["currentShareID"]
        raw = row
    }

    func matches(_ proof: OfflineSyncedMetadataProof, descriptors: [AutoFillCredentialDescriptor]) -> Bool {
        guard proof.shareID == shareID, proof.item.hasSameSourceMetadata(as: item),
              proof.metadataGeneration == uuid("currentMetadataGeneration") else { return false }
        let actual = descriptors.map(\.sourceInput)
        return Dictionary(grouping: actual, by: \.identityKey) == Dictionary(grouping: proof.descriptorInputs, by: \.identityKey)
    }

    func ownership(known entries: [Row]?, allowExpansion: Bool) -> OfflineSyncOwnership? {
        guard isNull("currentPendingRequestID") else { return nil }
        let known = entries?.first
        if let entries, entries.count != 1 { return nil }
        if let known {
            guard (known["vaultID"] as String) == item.vaultId else { return nil }
            let pending: DatabaseValue = known["pendingRequestID"]
            guard pending.isNull else { return nil }
            let selected: DatabaseValue = known["selectionGeneration"]
            if !selected.isNull { return selectedOwnership(known) }
            let wasEligible: Bool = known["wasEligibleForVaultSelection"]
            let wasExcluded: Bool = known["isExcluded"]
            guard wasEligible, !wasExcluded else { return nil }
        }
        guard !(raw["hasSelectedRow"] as Bool), allowExpansion, !(raw["currentExcluded"] as Bool),
              let policy = uuid("capturedPolicyGeneration"), policy == uuid("currentPolicyGeneration") else { return nil }
        return .vaultMember(policyGeneration: policy, wasKnownEligible: known != nil)
    }

    private func selectedOwnership(_ known: Row) -> OfflineSyncOwnership? {
        let hasSelectedRow: Bool = raw["hasSelectedRow"]
        guard hasSelectedRow, let selection = uuid("currentSelectionGeneration"),
              let request = uuid("currentRequestGeneration"), let metadata = uuid("currentMetadataGeneration"),
              selection == Self.uuid("selectionGeneration", in: known), request == Self.uuid("requestGeneration", in: known) else { return nil }
        if !(raw["currentManual"] as Bool) {
            guard !(raw["currentExcluded"] as Bool), let policy = uuid("capturedPolicyGeneration"),
                  policy == uuid("currentPolicyGeneration") else { return nil }
        }
        return .selected(selectionGeneration: selection, requestGeneration: request, metadataGeneration: metadata)
    }

    func canSkip(source: Date?, proof: OfflineSyncedMetadataProof) -> Bool {
        guard let source, let generation = proof.metadataGeneration,
              generation == uuid("snapshotMetadataGeneration"), (raw["cacheStatus"] as String?) == OfflineCacheStatus.cached.rawValue,
              (raw["snapshotSchemaVersion"] as Int?) == Int(OfflineSnapshotLimits.schemaVersion),
              uuid("snapshotRevision") != nil, (raw["fingerprintLength"] as Int?) == 32,
              let length: Int = raw["payloadLength"], length >= 28, length <= OfflineSnapshotLimits.ciphertextBytes else { return false }
        let stored: DatabaseValue = raw["snapshotSourceTime"]
        guard let baseline = Date.fromDatabaseValue(stored), baseline.timeIntervalSince1970.isFinite else { return false }
        return baseline == source
    }

    private func isNull(_ column: String) -> Bool { (raw[column] as DatabaseValue).isNull }
    private func uuid(_ column: String) -> UUID? { Self.uuid(column, in: raw) }
    private static func uuid(_ column: String, in row: Row) -> UUID? {
        let value: DatabaseValue = row[column]
        return String.fromDatabaseValue(value).flatMap(UUID.init(uuidString:))
    }
}
