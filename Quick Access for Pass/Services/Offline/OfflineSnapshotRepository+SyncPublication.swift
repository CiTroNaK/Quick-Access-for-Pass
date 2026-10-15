import Foundation
import GRDB

nonisolated extension OfflineSnapshotRepository {
    func publishSyncBatch(_ publications: [OfflineSyncPublication], capture: OfflineSyncCapture) async throws -> Set<OfflineSnapshotKey> {
        try Task.checkCancellation()
        try Self.validateSyncBatchSize(publications)
        let candidates = publications.filter(Self.isValidSyncEnvelope)
        guard !candidates.isEmpty else { return [] }
        do {
            let committed = try await database.writeOfflineMutation(
                submissionScope: .keys(Set(candidates.map { $0.work.key })),
                beforeWrite: { await prepareSyncPublicationSubmission() }, updates: { db in
                    let result = try Self.publishSyncCandidates(candidates, capture: capture, in: db)
                    return OfflineMutationUpdate(value: result, manualPromotions: [])
                }
            )
            // Native COMMIT is authoritative even if cancellation/operation replacement arrives while observing it.
            if !committed.isEmpty { await observeSyncPublicationCommit() }
            return committed
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OfflinePersistenceError {
            throw error
        } catch {
            throw OfflinePersistenceError.persistenceFailed
        }
    }

    func finishSyncFailures(_ work: [OfflineSyncWork], capture: OfflineSyncCapture) async throws {
        try Task.checkCancellation()
        guard work.count <= OfflineSyncPublicationLimits.items else { throw OfflinePersistenceError.payloadTooLarge }
        guard !work.isEmpty else { return }
        do {
            // Status/owner cleanup retains the same usable snapshot; it must not revoke unrelated or current releases.
            try await database.writeOfflineMutation(submissionScope: .none) { db in
                let owned = try Self.ownedSyncWork(work, capture: capture, in: db)
                for candidate in owned.values { try Self.writeSyncFailure(candidate, in: db) }
                return OfflineMutationUpdate(value: (), manualPromotions: [])
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OfflinePersistenceError.persistenceFailed
        }
    }

    private static func validateSyncBatchSize(_ publications: [OfflineSyncPublication]) throws {
        guard publications.count <= OfflineSyncPublicationLimits.items else { throw OfflinePersistenceError.payloadTooLarge }
        var total = 0
        for publication in publications {
            let count = publication.prepared.snapshot.payload.count
            guard count <= OfflineSyncPublicationLimits.ciphertextBytes - total else { throw OfflinePersistenceError.payloadTooLarge }
            total += count
        }
    }

    private static func isValidSyncEnvelope(_ publication: OfflineSyncPublication) -> Bool {
        let snapshot = publication.prepared.snapshot
        return snapshot.identity.key == publication.work.key && snapshot.identity.key.schemaVersion == OfflineSnapshotLimits.schemaVersion
            && snapshot.identity.keyFingerprint.count == 32 && snapshot.payload.count >= 28
            && snapshot.payload.count <= OfflineSnapshotLimits.ciphertextBytes
            && (publication.source == .liveFallback || publication.prepared.sourceModifyTime == publication.work.expectedSourceModifyTime)
            && publication.prepared.sourceModifyTime?.timeIntervalSince1970.isFinite != false
            && publication.refreshedAt.timeIntervalSince1970.isFinite
    }

    private static func publishSyncCandidates(
        _ publications: [OfflineSyncPublication], capture: OfflineSyncCapture, in db: Database
    ) throws -> Set<OfflineSnapshotKey> {
        let owned = try ownedSyncWork(publications.map(\.work), capture: capture, in: db)
        guard !owned.isEmpty else { return [] }
        let targets = try syncReplaceableTargets(itemIDs: Set(owned.keys.map(\.itemId)), in: db)
        let epochs = Set(try Data.fetchAll(db, sql: "SELECT DISTINCT keyFingerprint FROM offlineSnapshots"))
        guard epochs.count <= 1 else { return [] }
        var epoch = epochs.first
        var committed: Set<OfflineSnapshotKey> = []
        for publication in publications {
            let candidate = publication.work
            let fingerprint = publication.prepared.snapshot.identity.keyFingerprint
            guard let current = owned[candidate.key], sameSyncWork(candidate, current), !committed.contains(candidate.key),
                  targets[candidate.key] != false, epoch == nil || epoch == fingerprint else { continue }
            let metadata = try writeSyncSelection(candidate, refreshedAt: publication.refreshedAt, in: db)
            try writeSyncSnapshot(publication, metadataGeneration: metadata, in: db)
            epoch = fingerprint
            committed.insert(candidate.key)
        }
        return committed
    }
}
