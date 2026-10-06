import Foundation
import GRDB

// This file keeps the transaction predicates and their matching cleanup paths together.
// swiftlint:disable file_length type_body_length

/// Safe failures exposed by the offline persistence boundary.
nonisolated enum OfflinePersistenceError: Error, Equatable, Sendable {
    case itemUnavailable
    case identityChanged
    case unsupportedSchemaVersion
    case payloadTooLarge
    case persistenceFailed
}

/// Atomic lifecycle and authorization boundary for encrypted offline snapshots.
nonisolated protocol OfflineSnapshotPersisting: Sendable {
    func beginRequest(itemID: String, vaultID: String, shareID: String, kind: OfflineRequestKind,
                      expectedSelectionGeneration: UUID?, expectedMetadataModifyTime: Date?, expectedItemType: ItemType?) async throws -> OfflineRequestToken?
    func publish(_ snapshot: EncryptedOfflineSnapshot, for request: OfflineRequestToken, refreshedAt: Date) async throws -> Bool
    func finishRequest(_ request: OfflineRequestToken, failed: Bool) async throws
    func setVaultSelected(_ selected: Bool, vaultID: String) async throws -> OfflineVaultSelection?
    func selectItemManually(itemID: String, vaultID: String, shareID: String) async throws -> UUID
    func keepItemOfflineIndividually(itemID: String, vaultID: String) async throws
    func itemPolicy(itemID: String, vaultID: String) async throws -> OfflineItemPolicy?
    func workCandidates(vaultID: String?, includeNewSelections: Bool, refreshExisting: Bool) async throws -> [OfflineSnapshotWorkCandidate]
    func removeItem(_ itemID: String) async throws
    func purge() async throws
    func recoverAbandonedRequests() async throws
    func authorizedSnapshot(for key: OfflineSnapshotKey) async throws -> EncryptedOfflineSnapshot?
    func hasAuthorizedSnapshot(for key: OfflineSnapshotKey) async throws -> Bool
    func isAuthorized(_ snapshot: EncryptedOfflineSnapshot) async throws -> Bool
    func discardCorruptSnapshot(_ snapshot: EncryptedOfflineSnapshot) async throws
    func hasPersistedSnapshots() async throws -> Bool
    func offlineVaultIds() async throws -> Set<String>
    func offlineItemSelection(itemId: String) async throws -> OfflineItemSelection?
    func offlineItemSelections() async throws -> [OfflineItemSelection]
}

nonisolated extension OfflineSnapshotPersisting {
    func beginRequest(itemID: String, vaultID: String, shareID: String, kind: OfflineRequestKind) async throws -> OfflineRequestToken? {
        try await beginRequest(itemID: itemID, vaultID: vaultID, shareID: shareID, kind: kind,
                               expectedSelectionGeneration: nil, expectedMetadataModifyTime: nil, expectedItemType: nil)
    }
}

/// A stateless value facade over the app database. GRDB owns connection access and write serialization.
nonisolated struct OfflineSnapshotRepository: OfflineSnapshotPersisting, Sendable {
    let database: DatabaseManager
    private let beforePublication: @Sendable () async -> Void
    /// Test-only synchronous marker adjacent to writer submission; it receives no plaintext.
    private let publicationSubmissionMarker: @Sendable () -> Void
    private let afterPublication: @Sendable () async -> Void
    /// Optional metadata-only maintenance requester. It is deliberately not a
    /// key, cipher, snapshot, or error dependency.
    private let maintenance: OfflineStorageMaintenance?

    init(
        database: DatabaseManager,
        beforePublication: @escaping @Sendable () async -> Void = {},
        publicationSubmissionMarker: @escaping @Sendable () -> Void = {},
        afterPublication: @escaping @Sendable () async -> Void = {},
        maintenance: OfflineStorageMaintenance? = nil
    ) {
        self.database = database
        self.beforePublication = beforePublication
        self.publicationSubmissionMarker = publicationSubmissionMarker
        self.afterPublication = afterPublication
        self.maintenance = maintenance
    }

    // swiftlint:disable:next function_body_length
    func beginRequest(
        itemID: String,
        vaultID: String,
        shareID: String,
        kind: OfflineRequestKind,
        expectedSelectionGeneration: UUID? = nil,
        expectedMetadataModifyTime: Date? = nil,
        expectedItemType: ItemType? = nil
    ) async throws -> OfflineRequestToken? {
        do {
            return try await database.writer.write { db in
                guard let item = try Row.fetchOne(
                    db,
                    sql: "SELECT modifyTime, itemType, state FROM items WHERE id = ? AND vaultId = ?",
                    arguments: [itemID, vaultID]
                ) else {
                    throw OfflinePersistenceError.itemUnavailable
                }
                guard item["state"] as String == "Active" else {
                    throw OfflinePersistenceError.itemUnavailable
                }
                guard let storedShareID = try String.fetchOne(
                    db,
                    sql: "SELECT shareId FROM vaults WHERE id = ?",
                    arguments: [vaultID]
                ), storedShareID == shareID else {
                    throw OfflinePersistenceError.identityChanged
                }
                guard let modifyTime: Date = item["modifyTime"],
                      let rawItemType: String = item["itemType"],
                      let itemType = ItemType(rawValue: rawItemType) else {
                    throw OfflinePersistenceError.persistenceFailed
                }
                guard expectedMetadataModifyTime.map({ $0 == modifyTime }) ?? true,
                      expectedItemType.map({ $0 == itemType }) ?? true else { return nil }

                let currentPolicyGeneration = try String.fetchOne(db, sql: "SELECT policyGeneration FROM offlineVaults WHERE vaultId = ?", arguments: [vaultID]).flatMap(UUID.init(uuidString:))
                let existing = try Row.fetchOne(db, sql: "SELECT selectionGeneration, cacheStatus, pendingRequestId FROM offlineItems WHERE itemId = ? AND vaultId = ?", arguments: [itemID, vaultID])
                let storedSelectionGeneration: String? = existing?["selectionGeneration"]
                let existingGeneration = storedSelectionGeneration.flatMap(UUID.init(uuidString:))
                if existing != nil && existingGeneration == nil { throw OfflinePersistenceError.persistenceFailed }
                let isExcluded = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM offlineItemExclusions WHERE itemId = ? AND vaultId = ?)", arguments: [itemID, vaultID]) ?? false
                let selectionGeneration: UUID
                switch kind {
                case .selection:
                    selectionGeneration = existingGeneration ?? UUID()
                    try db.execute(sql: "DELETE FROM offlineItemExclusions WHERE itemId = ? AND vaultId = ?", arguments: [itemID, vaultID])
                    if existing == nil {
                        try db.execute(
                            sql: """
                                INSERT INTO offlineItems
                                (itemId, vaultId, selectedAt, lastRefreshedAt, cacheStatus, pendingRequestId, isManuallySelected, selectionGeneration)
                                VALUES (?, ?, ?, NULL, ?, NULL, 1, ?)
                                """,
                            arguments: [itemID, vaultID, Date(), OfflineCacheStatus.notCached.rawValue, selectionGeneration.uuidString]
                        )
                    } else {
                        try db.execute(sql: "UPDATE offlineItems SET isManuallySelected = 1 WHERE itemId = ? AND vaultId = ?", arguments: [itemID, vaultID])
                    }
                case .materialization:
                    guard let expectedSelectionGeneration, expectedSelectionGeneration == existingGeneration,
                          !isExcluded,
                          try Bool.fetchOne(
                            db,
                            sql: "SELECT EXISTS(SELECT 1 FROM offlineItems o WHERE o.itemId = ? AND o.vaultId = ? AND \(OfflineSelectionSQL.effectiveSelection))",
                            arguments: [itemID, vaultID]
                          ) == true else { return nil }
                    selectionGeneration = expectedSelectionGeneration
                case .vaultSelection(let policyGeneration):
                    guard currentPolicyGeneration == policyGeneration, !isExcluded else { return nil }
                    selectionGeneration = existingGeneration ?? UUID()
                    if existing == nil {
                        try db.execute(
                            sql: """
                                INSERT INTO offlineItems
                                (itemId, vaultId, selectedAt, lastRefreshedAt, cacheStatus, pendingRequestId, isManuallySelected, selectionGeneration)
                                VALUES (?, ?, ?, NULL, ?, NULL, 0, ?)
                                """,
                            arguments: [itemID, vaultID, Date(), OfflineCacheStatus.notCached.rawValue, selectionGeneration.uuidString]
                        )
                    }
                case .refresh:
                    guard let existingGeneration, expectedSelectionGeneration.map({ $0 == existingGeneration }) ?? true,
                          let cacheStatus = existing?["cacheStatus"] as String?,
                          cacheStatus == OfflineCacheStatus.cached.rawValue || cacheStatus == OfflineCacheStatus.failed.rawValue,
                          try Bool.fetchOne(
                            db,
                            sql: "SELECT EXISTS(SELECT 1 FROM offlineItems o WHERE o.itemId = ? AND o.vaultId = ? AND \(OfflineSelectionSQL.effectiveSelection))",
                            arguments: [itemID, vaultID]
                          ) == true,
                          let metadata = try Self.authorizedMetadata(for: OfflineSnapshotKey(vaultId: vaultID, itemId: itemID, schemaVersion: OfflineSnapshotLimits.schemaVersion), in: db),
                          metadata.isStructurallyUsable else { return nil }
                    selectionGeneration = existingGeneration
                }
                if let pending = existing?["pendingRequestId"] as String?, !pending.isEmpty, kind != .selection { return nil }

                let requestID = UUID()
                try db.execute(
                    sql: "UPDATE offlineItems SET pendingRequestId = ? WHERE itemId = ? AND vaultId = ?",
                    arguments: [requestID.uuidString, itemID, vaultID]
                )
                guard let modifyTime: Date = item["modifyTime"],
                      let rawItemType: String = item["itemType"],
                      let itemType = ItemType(rawValue: rawItemType) else {
                    throw OfflinePersistenceError.persistenceFailed
                }
                return OfflineRequestToken(
                    id: requestID,
                    key: OfflineSnapshotKey(vaultId: vaultID, itemId: itemID, schemaVersion: OfflineSnapshotLimits.schemaVersion),
                    shareID: shareID,
                    metadataModifyTime: modifyTime,
                    itemType: itemType,
                    selectionGeneration: selectionGeneration
                )
            }
        } catch let error as OfflinePersistenceError {
            throw error
        } catch {
            throw OfflinePersistenceError.persistenceFailed
        }
    }

    // swiftlint:disable:next function_body_length
    func publish(
        _ snapshot: EncryptedOfflineSnapshot,
        for request: OfflineRequestToken,
        refreshedAt: Date
    ) async throws -> Bool {
        try validate(snapshot: snapshot, matches: request)
        await beforePublication()
        publicationSubmissionMarker()
        do {
            let published = try await database.writer.write { db in
                let predicate = try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) FROM offlineItems o
                    JOIN items i ON i.id = o.itemId AND i.vaultId = o.vaultId
                    JOIN vaults v ON v.id = o.vaultId
                    WHERE o.itemId = ? AND o.vaultId = ? AND o.pendingRequestId = ?
                      AND o.selectionGeneration = ? AND i.state = 'Active'
                      AND i.modifyTime = ? AND i.itemType = ? AND v.shareId = ?
                      AND \(OfflineSelectionSQL.effectiveSelection)
                    """,
                    arguments: [
                        request.key.itemId,
                        request.key.vaultId,
                        request.id.uuidString,
                        request.selectionGeneration.uuidString,
                        request.metadataModifyTime,
                        request.itemType.rawValue,
                        request.shareID
                    ]
                ) ?? 0
                guard predicate == 1 else { return false }

                let mismatchedEpoch = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM offlineSnapshots WHERE keyFingerprint != ?)",
                    arguments: [snapshot.identity.keyFingerprint]
                ) ?? false
                guard !mismatchedEpoch else { return false }

                // A target replaced during the fetch is never implicitly migrated
                // or repaired. Absent targets remain valid for first selections.
                let hasTarget = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM offlineSnapshots WHERE vaultId = ? AND itemId = ?)",
                                                 arguments: [request.key.vaultId, request.key.itemId]) ?? false
                if hasTarget {
                    guard let metadata = try Self.authorizedMetadata(for: request.key, in: db), metadata.isStructurallyUsable else { return false }
                }

                try db.execute(
                    sql: """
                    INSERT INTO offlineSnapshots
                    (vaultId, itemId, schemaVersion, snapshotRevision, keyFingerprint, encryptedPayload)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(vaultId, itemId) DO UPDATE SET
                        schemaVersion = excluded.schemaVersion,
                        snapshotRevision = excluded.snapshotRevision,
                        keyFingerprint = excluded.keyFingerprint,
                        encryptedPayload = excluded.encryptedPayload
                    """,
                    arguments: [
                        request.key.vaultId,
                        request.key.itemId,
                        snapshot.identity.key.schemaVersion,
                        snapshot.identity.revision.uuidString,
                        snapshot.identity.keyFingerprint,
                        snapshot.payload
                    ]
                )
                try db.execute(
                    sql: """
                    UPDATE offlineItems
                    SET cacheStatus = ?, lastRefreshedAt = ?, pendingRequestId = NULL
                    WHERE itemId = ? AND vaultId = ? AND pendingRequestId = ?
                    """,
                    arguments: [
                        OfflineCacheStatus.cached.rawValue,
                        refreshedAt,
                        request.key.itemId,
                        request.key.vaultId,
                        request.id.uuidString
                    ]
                )
                return true
            }
            await afterPublication()
            return published
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OfflinePersistenceError {
            throw error
        } catch {
            throw OfflinePersistenceError.persistenceFailed
        }
    }

    func finishRequest(_ request: OfflineRequestToken, failed: Bool) async throws {
        do {
            try await database.writer.write { db in
                guard try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM offlineItems WHERE itemId = ? AND vaultId = ? AND pendingRequestId = ?)",
                    arguments: [request.key.itemId, request.key.vaultId, request.id.uuidString]
                ) == true else { return }

                let hasPayload = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM offlineSnapshots WHERE vaultId = ? AND itemId = ?)",
                    arguments: [request.key.vaultId, request.key.itemId]
                ) ?? false
                if failed, hasPayload {
                    try db.execute(
                        sql: "UPDATE offlineItems SET cacheStatus = ?, pendingRequestId = NULL WHERE itemId = ? AND vaultId = ? AND pendingRequestId = ?",
                        arguments: [OfflineCacheStatus.failed.rawValue, request.key.itemId, request.key.vaultId, request.id.uuidString]
                    )
                } else if !hasPayload {
                    try db.execute(
                        sql: "UPDATE offlineItems SET cacheStatus = ?, pendingRequestId = NULL WHERE itemId = ? AND vaultId = ? AND pendingRequestId = ?",
                        arguments: [OfflineCacheStatus.unavailable.rawValue, request.key.itemId, request.key.vaultId, request.id.uuidString]
                    )
                } else {
                    try db.execute(
                        sql: "UPDATE offlineItems SET pendingRequestId = NULL WHERE itemId = ? AND vaultId = ? AND pendingRequestId = ?",
                        arguments: [request.key.itemId, request.key.vaultId, request.id.uuidString]
                    )
                }
            }
        } catch {
            throw OfflinePersistenceError.persistenceFailed
        }
    }

    func setVaultSelected(_ selected: Bool, vaultID: String) async throws -> OfflineVaultSelection? {
        do {
            let result = try await database.writer.write { db -> (OfflineVaultSelection?, Bool) in
                if selected {
                    guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM vaults WHERE id = ?)", arguments: [vaultID]) == true else {
                        throw OfflinePersistenceError.itemUnavailable
                    }
                    try db.execute(
                        sql: "INSERT INTO offlineVaults (vaultId, enabledAt, policyGeneration) VALUES (?, ?, ?) ON CONFLICT(vaultId) DO NOTHING",
                        arguments: [vaultID, Date(), UUID().uuidString]
                    )
                    guard let storedGeneration = try String.fetchOne(
                        db,
                        sql: "SELECT policyGeneration FROM offlineVaults WHERE vaultId = ?",
                        arguments: [vaultID]
                    ), let generation = UUID(uuidString: storedGeneration) else {
                        throw OfflinePersistenceError.persistenceFailed
                    }
                    return (OfflineVaultSelection(vaultID: vaultID, generation: generation), false)
                }
                let policyExists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM offlineVaults WHERE vaultId = ?)", arguments: [vaultID]) ?? false
                let vaultOnlyCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineItems WHERE vaultId = ? AND isManuallySelected = 0", arguments: [vaultID]) ?? 0
                try db.execute(sql: "DELETE FROM offlineItems WHERE vaultId = ? AND isManuallySelected = 0", arguments: [vaultID])
                try db.execute(sql: "DELETE FROM offlineVaults WHERE vaultId = ?", arguments: [vaultID])
                return (nil, policyExists || vaultOnlyCount > 0)
            }
            if result.1 { await maintenance?.requestCheckpoint() }
            return result.0
        } catch let error as OfflinePersistenceError {
            throw error
        } catch {
            throw OfflinePersistenceError.persistenceFailed
        }
    }

    func removeItem(_ itemID: String) async throws {
        do {
            let didDeleteOfflineData = try await database.writer.write { db in
                guard let vaultID = try String.fetchOne(db, sql: "SELECT vaultId FROM items WHERE id = ?", arguments: [itemID]) else {
                    return false
                }
                let vaultSelected = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM offlineVaults WHERE vaultId = ?)", arguments: [vaultID]) ?? false
                let didDelete = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineItems WHERE itemId = ?", arguments: [itemID]) ?? 0) > 0
                if vaultSelected {
                    try db.execute(sql: "INSERT INTO offlineItemExclusions (itemId, vaultId) VALUES (?, ?) ON CONFLICT DO NOTHING", arguments: [itemID, vaultID])
                }
                try db.execute(sql: "DELETE FROM offlineItems WHERE itemId = ?", arguments: [itemID])
                return didDelete
            }
            if didDeleteOfflineData { await maintenance?.requestCheckpoint() }
        } catch {
            throw OfflinePersistenceError.persistenceFailed
        }
    }

    func purge() async throws {
        do {
            let didDeleteOfflineData = try await database.writer.write { db in
                let itemCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineItems") ?? 0
                let vaultCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineVaults") ?? 0
                let exclusionCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineItemExclusions") ?? 0
                let didDelete = itemCount > 0 || vaultCount > 0 || exclusionCount > 0
                try db.execute(sql: "DELETE FROM offlineItems")
                try db.execute(sql: "DELETE FROM offlineVaults")
                try db.execute(sql: "DELETE FROM offlineItemExclusions")
                return didDelete
            }
            if didDeleteOfflineData { await maintenance?.requestCheckpoint() }
        } catch {
            throw OfflinePersistenceError.persistenceFailed
        }
    }

    func recoverAbandonedRequests() async throws {
        do {
            try await database.writer.write { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT o.itemId, o.vaultId, o.cacheStatus,
                           s.schemaVersion, s.snapshotRevision, s.keyFingerprint,
                           length(s.encryptedPayload) AS payloadLength
                    FROM offlineItems o
                    LEFT JOIN offlineSnapshots s ON s.vaultId = o.vaultId AND s.itemId = o.itemId
                    """)
                for row in rows {
                    guard let itemID: String = row["itemId"],
                          let vaultID: String = row["vaultId"] else {
                        throw OfflinePersistenceError.persistenceFailed
                    }
                    let cacheStatus: String = row["cacheStatus"]
                    let schemaVersion: UInt8? = row["schemaVersion"]
                    let revisionString: String? = row["snapshotRevision"]
                    let fingerprint: Data? = row["keyFingerprint"]
                    let payloadLength: Int? = row["payloadLength"]
                    let hasUsableSnapshot =
                        (cacheStatus == OfflineCacheStatus.cached.rawValue || cacheStatus == OfflineCacheStatus.failed.rawValue)
                        && schemaVersion == OfflineSnapshotLimits.schemaVersion
                        && revisionString.flatMap(UUID.init(uuidString:)) != nil
                        && fingerprint?.count == 32
                        && payloadLength.map { $0 >= 28 && $0 <= OfflineSnapshotLimits.ciphertextBytes } == true
                    if hasUsableSnapshot {
                        try db.execute(
                            sql: "UPDATE offlineItems SET pendingRequestId = NULL WHERE itemId = ? AND vaultId = ?",
                            arguments: [itemID, vaultID]
                        )
                    } else {
                        try db.execute(
                            sql: "UPDATE offlineItems SET cacheStatus = ?, pendingRequestId = NULL WHERE itemId = ? AND vaultId = ?",
                            arguments: [OfflineCacheStatus.unavailable.rawValue, itemID, vaultID]
                        )
                    }
                }
            }
        } catch let error as OfflinePersistenceError {
            throw error
        } catch {
            throw OfflinePersistenceError.persistenceFailed
        }
    }

    func authorizedSnapshot(for key: OfflineSnapshotKey) async throws -> EncryptedOfflineSnapshot? {
        try validate(schemaVersion: key.schemaVersion)
        do {
            guard let metadata = try await authorizedMetadata(for: key) else { return nil }
            guard metadata.payloadLength >= OfflineSnapshotLimits.ciphertextBytes - OfflineSnapshotLimits.plaintextBytes,
                  metadata.payloadLength <= OfflineSnapshotLimits.ciphertextBytes else {
                throw OfflinePersistenceError.payloadTooLarge
            }
            guard let payload = try await database.reader.read({ db in
                try Data.fetchOne(
                    db,
                    sql: """
                    SELECT encryptedPayload FROM offlineSnapshots
                    WHERE vaultId = ? AND itemId = ? AND schemaVersion = ?
                      AND snapshotRevision = ? AND keyFingerprint = ?
                      AND length(encryptedPayload) = ?
                    """,
                    arguments: [key.vaultId, key.itemId, key.schemaVersion, metadata.revision.uuidString, metadata.fingerprint, metadata.payloadLength]
                )
            }) else { return nil }
            return EncryptedOfflineSnapshot(
                identity: OfflineSnapshotIdentity(key: key, revision: metadata.revision, keyFingerprint: metadata.fingerprint),
                payload: payload
            )
        } catch let error as OfflinePersistenceError {
            throw error
        } catch {
            throw OfflinePersistenceError.persistenceFailed
        }
    }

    func hasAuthorizedSnapshot(for key: OfflineSnapshotKey) async throws -> Bool {
        try validate(schemaVersion: key.schemaVersion)
        do {
            guard let metadata = try await authorizedMetadata(for: key) else { return false }
            guard metadata.payloadLength >= 28, metadata.payloadLength <= OfflineSnapshotLimits.ciphertextBytes else {
                return false
            }
            return true
        } catch let error as OfflinePersistenceError {
            throw error
        } catch {
            throw OfflinePersistenceError.persistenceFailed
        }
    }

    func isAuthorized(_ snapshot: EncryptedOfflineSnapshot) async throws -> Bool {
        try validate(snapshot: snapshot)
        do {
            return try await database.reader.read { db in
                (try Bool.fetchOne(
                    db,
                    sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM offlineSnapshots s
                        JOIN offlineItems o ON o.itemId = s.itemId AND o.vaultId = s.vaultId
                        JOIN items i ON i.id = o.itemId AND i.vaultId = o.vaultId
                        JOIN vaults v ON v.id = o.vaultId
                        WHERE s.vaultId = ? AND s.itemId = ? AND s.schemaVersion = ?
                          AND s.snapshotRevision = ? AND s.keyFingerprint = ? AND s.encryptedPayload = ?
                          AND i.state = 'Active' AND o.cacheStatus IN (?, ?)
                          AND \(OfflineSelectionSQL.effectiveSelection)
                    )
                    """,
                    arguments: [
                        snapshot.identity.key.vaultId,
                        snapshot.identity.key.itemId,
                        snapshot.identity.key.schemaVersion,
                        snapshot.identity.revision.uuidString,
                        snapshot.identity.keyFingerprint,
                        snapshot.payload,
                        OfflineCacheStatus.cached.rawValue,
                        OfflineCacheStatus.failed.rawValue
                    ]
                ) ?? false)
            }
        } catch let error as OfflinePersistenceError {
            throw error
        } catch {
            throw OfflinePersistenceError.persistenceFailed
        }
    }

    func discardCorruptSnapshot(_ snapshot: EncryptedOfflineSnapshot) async throws {
        try validate(snapshot: snapshot)
        do {
            let didDeleteSnapshot = try await database.writer.write { db in
                try db.execute(
                    sql: """
                    DELETE FROM offlineSnapshots
                    WHERE vaultId = ? AND itemId = ? AND schemaVersion = ?
                      AND snapshotRevision = ? AND keyFingerprint = ? AND encryptedPayload = ?
                    """,
                    arguments: [
                        snapshot.identity.key.vaultId,
                        snapshot.identity.key.itemId,
                        snapshot.identity.key.schemaVersion,
                        snapshot.identity.revision.uuidString,
                        snapshot.identity.keyFingerprint,
                        snapshot.payload
                    ]
                )
                guard db.changesCount > 0 else { return false }
                try db.execute(
                    sql: """
                    UPDATE offlineItems SET cacheStatus = ?, pendingRequestId = NULL
                    WHERE itemId = ? AND vaultId = ? AND NOT EXISTS (
                        SELECT 1 FROM offlineSnapshots s
                        WHERE s.vaultId = offlineItems.vaultId AND s.itemId = offlineItems.itemId
                    )
                    """,
                    arguments: [OfflineCacheStatus.unavailable.rawValue, snapshot.identity.key.itemId, snapshot.identity.key.vaultId]
                )
                return true
            }
            if didDeleteSnapshot { await maintenance?.requestCheckpoint() }
        } catch let error as OfflinePersistenceError {
            throw error
        } catch {
            throw OfflinePersistenceError.persistenceFailed
        }
    }

    func hasPersistedSnapshots() async throws -> Bool {
        do {
            return try await database.reader.read { db in
                (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineSnapshots") ?? 0) > 0
            }
        } catch {
            throw OfflinePersistenceError.persistenceFailed
        }
    }

    func offlineVaultIds() async throws -> Set<String> {
        do {
            return try await database.reader.read { db in
                Set(try String.fetchAll(db, sql: "SELECT vaultId FROM offlineVaults"))
            }
        } catch {
            throw OfflinePersistenceError.persistenceFailed
        }
    }

    func offlineItemSelection(itemId: String) async throws -> OfflineItemSelection? {
        do {
            return try await database.reader.read { db in
                try OfflineItemSelection.fetchOne(
                    db,
                    sql: """
                    SELECT o.* FROM offlineItems o
                    JOIN items i ON i.id = o.itemId AND i.vaultId = o.vaultId
                    WHERE o.itemId = ? AND i.state = 'Active'
                      AND \(OfflineSelectionSQL.effectiveSelection)
                    """,
                    arguments: [itemId]
                )
            }
        } catch {
            throw OfflinePersistenceError.persistenceFailed
        }
    }

    func offlineItemSelections() async throws -> [OfflineItemSelection] {
        do {
            return try await database.reader.read { db in
                try OfflineItemSelection.order(Column("itemId").asc).fetchAll(db)
            }
        } catch {
            throw OfflinePersistenceError.persistenceFailed
        }
    }

    private func authorizedMetadata(for key: OfflineSnapshotKey) async throws -> SnapshotMetadata? {
        try await database.reader.read { db in
            try Self.authorizedMetadata(for: key, in: db)
        }
    }

    private static func authorizedMetadata(for key: OfflineSnapshotKey, in db: Database) throws -> SnapshotMetadata? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT s.schemaVersion, s.snapshotRevision, s.keyFingerprint, length(s.encryptedPayload) AS payloadLength
            FROM offlineSnapshots s
            JOIN offlineItems o ON o.itemId = s.itemId AND o.vaultId = s.vaultId
            JOIN items i ON i.id = o.itemId AND i.vaultId = o.vaultId
            JOIN vaults v ON v.id = o.vaultId
            WHERE s.vaultId = ? AND s.itemId = ? AND s.schemaVersion = ?
              AND i.state = 'Active' AND o.cacheStatus IN (?, ?)
              AND \(OfflineSelectionSQL.effectiveSelection)
            """,
            arguments: [key.vaultId, key.itemId, key.schemaVersion, OfflineCacheStatus.cached.rawValue, OfflineCacheStatus.failed.rawValue]
        ),
        let schemaVersion: UInt8 = row["schemaVersion"],
        let revisionString: String = row["snapshotRevision"],
        let revision = UUID(uuidString: revisionString),
        let fingerprint: Data = row["keyFingerprint"],
        let payloadLength: Int = row["payloadLength"] else {
            return nil
        }
        guard schemaVersion == OfflineSnapshotLimits.schemaVersion else {
            throw OfflinePersistenceError.unsupportedSchemaVersion
        }
        guard fingerprint.count == 32 else { throw OfflinePersistenceError.persistenceFailed }
        return SnapshotMetadata(revision: revision, fingerprint: fingerprint, payloadLength: payloadLength)
    }

    private func validate(snapshot: EncryptedOfflineSnapshot, matches request: OfflineRequestToken? = nil) throws {
        try validate(schemaVersion: snapshot.identity.key.schemaVersion)
        guard snapshot.identity.keyFingerprint.count == 32 else { throw OfflinePersistenceError.persistenceFailed }
        guard snapshot.payload.count <= OfflineSnapshotLimits.ciphertextBytes else { throw OfflinePersistenceError.payloadTooLarge }
        guard snapshot.payload.count >= 28 else { throw OfflinePersistenceError.persistenceFailed }
        if let request, snapshot.identity.key != request.key {
            throw OfflinePersistenceError.identityChanged
        }
    }

    private func validate(schemaVersion: UInt8) throws {
        guard schemaVersion == OfflineSnapshotLimits.schemaVersion else {
            throw OfflinePersistenceError.unsupportedSchemaVersion
        }
    }

    private struct SnapshotMetadata: Sendable {
        let revision: UUID
        let fingerprint: Data
        let payloadLength: Int

        var isStructurallyUsable: Bool {
            payloadLength >= 28 && payloadLength <= OfflineSnapshotLimits.ciphertextBytes
        }
    }
}

// swiftlint:enable file_length type_body_length
