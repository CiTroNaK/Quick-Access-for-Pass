import Foundation
import GRDB

nonisolated extension OfflineSnapshotRepository {
    /// Original operation-produced proofs are rechecked, not replaced with a later projection.
    static func ownedSyncWork(_ work: [OfflineSyncWork], capture: OfflineSyncCapture, in db: Database) throws -> [OfflineSnapshotKey: OfflineSyncWork] {
        let proofs = Dictionary(work.map { ($0.key, $0.metadataProof) }, uniquingKeysWith: { first, _ in first })
        let times = Dictionary(work.compactMap { candidate in candidate.expectedSourceModifyTime.map { (candidate.key.itemId, $0) } },
                               uniquingKeysWith: { first, _ in first })
        let current = try syncWork(capture: capture, metadataProofs: proofs, sourceTimes: times, allowMembershipExpansion: true,
                                   itemIDs: Set(work.map { $0.key.itemId }), in: db)
        let byKey = Dictionary(uniqueKeysWithValues: current.map { ($0.key, $0) })
        var owned: [OfflineSnapshotKey: OfflineSyncWork] = [:]
        for candidate in work {
            guard candidate.capturedPendingRequestID == nil, let fresh = byKey[candidate.key],
                  sameSyncWork(fresh, candidate) else { continue }
            owned[candidate.key] = candidate
        }
        return owned
    }

    static func sameSyncWork(_ lhs: OfflineSyncWork, _ rhs: OfflineSyncWork) -> Bool {
        lhs.key == rhs.key && lhs.ownership == rhs.ownership && lhs.shareID == rhs.shareID && lhs.itemType == rhs.itemType
            && lhs.capturedPendingRequestID == rhs.capturedPendingRequestID && lhs.expectedSourceModifyTime == rhs.expectedSourceModifyTime
            && lhs.metadataProof.operationID == rhs.metadataProof.operationID && lhs.metadataProof.shareID == rhs.metadataProof.shareID
            && lhs.metadataProof.metadataGeneration == rhs.metadataProof.metadataGeneration
            && lhs.metadataProof.item.hasSameSourceMetadata(as: rhs.metadataProof.item)
            && lhs.metadataProof.item.modifyTime == rhs.metadataProof.item.modifyTime
            && Dictionary(grouping: lhs.metadataProof.descriptorInputs, by: \.identityKey)
                == Dictionary(grouping: rhs.metadataProof.descriptorInputs, by: \.identityKey)
    }

    /// Only format/status metadata is read; no existing ciphertext enters the writer's comparison state.
    static func syncReplaceableTargets(itemIDs: Set<String>, in db: Database) throws -> [OfflineSnapshotKey: Bool] {
        guard !itemIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: itemIDs.count).joined(separator: ",")
        let rows = try Row.fetchAll(db, sql: """
            SELECT s.vaultId, s.itemId, s.schemaVersion, s.snapshotRevision,
                   length(s.keyFingerprint) AS fingerprintLength, length(s.encryptedPayload) AS payloadLength, o.cacheStatus
            FROM offlineSnapshots s JOIN offlineItems o ON o.itemId = s.itemId AND o.vaultId = s.vaultId
            WHERE s.itemId IN (\(placeholders))
            """, arguments: StatementArguments(itemIDs.sorted()))
        return Dictionary(uniqueKeysWithValues: rows.map { row in
            let key = OfflineSnapshotKey(vaultId: row["vaultId"], itemId: row["itemId"], schemaVersion: OfflineSnapshotLimits.schemaVersion)
            let revision: String = row["snapshotRevision"]
            let length: Int = row["payloadLength"]
            let status: String = row["cacheStatus"]
            let usable = (row["schemaVersion"] as Int) == Int(OfflineSnapshotLimits.schemaVersion) && UUID(uuidString: revision) != nil
                && (row["fingerprintLength"] as Int) == 32 && length >= 28 && length <= OfflineSnapshotLimits.ciphertextBytes
                && [OfflineCacheStatus.cached.rawValue, OfflineCacheStatus.failed.rawValue].contains(status)
            return (key, usable)
        })
    }

    static func writeSyncSelection(_ work: OfflineSyncWork, refreshedAt: Date, in db: Database) throws -> UUID {
        switch work.ownership {
        case .selected(let selection, let request, let metadata):
            try db.execute(sql: """
                UPDATE offlineItems SET cacheStatus = ?, lastRefreshedAt = ?, requestGeneration = ?
                WHERE itemId = ? AND vaultId = ? AND selectionGeneration = ? AND requestGeneration = ?
                  AND metadataGeneration = ? AND pendingRequestId IS NULL
                """, arguments: [OfflineCacheStatus.cached.rawValue, refreshedAt, UUID().uuidString,
                                 work.key.itemId, work.key.vaultId, selection.uuidString, request.uuidString, metadata.uuidString])
            guard db.changesCount == 1 else { throw OfflinePersistenceError.persistenceFailed }
            return metadata
        case .vaultMember:
            let metadata = UUID()
            try db.execute(sql: """
                INSERT INTO offlineItems
                    (itemId, vaultId, selectedAt, lastRefreshedAt, cacheStatus, selectionGeneration,
                     isManuallySelected, metadataGeneration, requestGeneration, pendingRequestId)
                VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, NULL)
                """, arguments: [work.key.itemId, work.key.vaultId, refreshedAt, refreshedAt, OfflineCacheStatus.cached.rawValue,
                                 UUID().uuidString, metadata.uuidString, UUID().uuidString])
            return metadata
        }
    }

    static func writeSyncSnapshot(_ publication: OfflineSyncPublication, metadataGeneration: UUID, in db: Database) throws {
        let snapshot = publication.prepared.snapshot
        try db.execute(sql: """
            INSERT INTO offlineSnapshots
                (vaultId, itemId, schemaVersion, snapshotRevision, keyFingerprint, encryptedPayload, sourceModifyTime, metadataGeneration)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(vaultId, itemId) DO UPDATE SET
                schemaVersion = excluded.schemaVersion, snapshotRevision = excluded.snapshotRevision,
                keyFingerprint = excluded.keyFingerprint, encryptedPayload = excluded.encryptedPayload,
                sourceModifyTime = excluded.sourceModifyTime, metadataGeneration = excluded.metadataGeneration
            """, arguments: [publication.work.key.vaultId, publication.work.key.itemId, snapshot.identity.key.schemaVersion,
                             snapshot.identity.revision.uuidString, snapshot.identity.keyFingerprint, snapshot.payload,
                             publication.prepared.sourceModifyTime?.timeIntervalSince1970, metadataGeneration.uuidString])
    }

    static func writeSyncFailure(_ work: OfflineSyncWork, in db: Database) throws {
        guard case .selected(let selection, let request, let metadata) = work.ownership else { return }
        try db.execute(sql: """
            UPDATE offlineItems
            SET cacheStatus = CASE WHEN EXISTS(SELECT 1 FROM offlineSnapshots s WHERE s.itemId = ? AND s.vaultId = ?)
                                  THEN ? ELSE ? END, requestGeneration = ?
            WHERE itemId = ? AND vaultId = ? AND selectionGeneration = ? AND requestGeneration = ?
              AND metadataGeneration = ? AND pendingRequestId IS NULL
            """, arguments: [work.key.itemId, work.key.vaultId, OfflineCacheStatus.failed.rawValue, OfflineCacheStatus.unavailable.rawValue,
                             UUID().uuidString, work.key.itemId, work.key.vaultId, selection.uuidString, request.uuidString, metadata.uuidString])
    }
}
