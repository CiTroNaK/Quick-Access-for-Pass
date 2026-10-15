import Foundation
@testable import Quick_Access_for_Pass

/// Metadata-only instrumentation over the real repository. No ciphertext or decoded item is retained.
actor IncrementalSyncRepository {
    let base: OfflineSnapshotRepository
    nonisolated var releaseAuthority: OfflineReleaseAuthority { base.releaseAuthority }
    private var captureGate: IncrementalSyncGate?
    private var publicationGate: OfflineTestGate?
    private var failCapture = false
    private var ends = 0
    private var endWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var batches: [(count: Int, bytes: Int)] = []
    init(base: OfflineSnapshotRepository) { self.base = base }
    func setCaptureGate(_ gate: IncrementalSyncGate?) { captureGate = gate }
    func setPublicationGate(_ gate: OfflineTestGate?) { publicationGate = gate }
    func setCaptureFailure(_ fail: Bool) { failCapture = fail }
    func endCount() -> Int { ends }
    func batchCounts() -> [Int] { batches.map(\.count) }
    func batchBytes() -> [Int] { batches.map(\.bytes) }
    func waitForEnd(_ count: Int) async {
        if ends < count { await withCheckedContinuation { endWaiters.append((count, $0)) } }
    }
    func beginSyncCapture(operation: SyncOperationToken, lifecycleGeneration: UUID) async throws -> OfflineSyncCapture {
        if failCapture { throw OfflinePersistenceError.persistenceFailed }
        let capture = try await base.beginSyncCapture(operation: operation, lifecycleGeneration: lifecycleGeneration)
        await captureGate?.wait()
        return capture
    }
    func endSyncCapture(_ capture: OfflineSyncCapture) async throws {
        try await base.endSyncCapture(capture)
        ends += 1
        let completed = endWaiters.filter { $0.0 <= ends }
        endWaiters.removeAll { $0.0 <= ends }
        completed.forEach { $0.1.resume() }
    }
    func syncWork(capture: OfflineSyncCapture, metadataProofs: [OfflineSnapshotKey: OfflineSyncedMetadataProof],
                  sourceTimes: [String: Date], allowMembershipExpansion: Bool) async throws -> [OfflineSyncWork] {
        try await base.syncWork(capture: capture, metadataProofs: metadataProofs, sourceTimes: sourceTimes,
                                allowMembershipExpansion: allowMembershipExpansion)
    }
    func publishSyncBatch(_ publications: [OfflineSyncPublication], capture: OfflineSyncCapture) async throws -> Set<OfflineSnapshotKey> {
        batches.append((publications.count, publications.reduce(0) { $0 + $1.prepared.snapshot.payload.count }))
        try await publicationGate?.wait()
        return try await base.publishSyncBatch(publications, capture: capture)
    }
    func finishSyncFailures(_ work: [OfflineSyncWork], capture: OfflineSyncCapture) async throws {
        try await base.finishSyncFailures(work, capture: capture)
    }
    func releaseProof(for snapshot: EncryptedOfflineSnapshot) async throws -> OfflineReleaseProof? { try await base.releaseProof(for: snapshot) }
    func beginRequest(itemID: String, vaultID: String, shareID: String, kind: OfflineRequestKind,
                      expectations: OfflineRequestExpectations) async throws -> OfflineRequestToken? {
        try await base.beginRequest(itemID: itemID, vaultID: vaultID, shareID: shareID, kind: kind, expectations: expectations)
    }
    func publish(_ snapshot: PreparedOfflineSnapshot, for request: OfflineRequestToken, refreshedAt: Date) async throws -> Bool {
        try await base.publish(snapshot, for: request, refreshedAt: refreshedAt)
    }
    func finishRequest(_ request: OfflineRequestToken, failed: Bool) async throws { try await base.finishRequest(request, failed: failed) }
    func setVaultSelected(_ selected: Bool, vaultID: String) async throws -> OfflineVaultSelection? {
        try await base.setVaultSelected(selected, vaultID: vaultID)
    }
    func selectItemManually(itemID: String, vaultID: String, shareID: String) async throws -> UUID {
        try await base.selectItemManually(itemID: itemID, vaultID: vaultID, shareID: shareID)
    }
    func keepItemOfflineIndividually(itemID: String, vaultID: String) async throws { try await base.keepItemOfflineIndividually(itemID: itemID, vaultID: vaultID) }
    func itemPolicy(itemID: String, vaultID: String) async throws -> OfflineItemPolicy? { try await base.itemPolicy(itemID: itemID, vaultID: vaultID) }
    func workCandidates(vaultID: String?, includeNewSelections: Bool, refreshExisting: Bool) async throws -> [OfflineSnapshotWorkCandidate] {
        try await base.workCandidates(vaultID: vaultID, includeNewSelections: includeNewSelections, refreshExisting: refreshExisting)
    }
    func workCandidateForSelectedItem(itemID: String, vaultID: String) async throws -> OfflineSnapshotWorkCandidate? {
        try await base.workCandidateForSelectedItem(itemID: itemID, vaultID: vaultID)
    }
    func removeItem(_ itemID: String) async throws { try await base.removeItem(itemID) }
    func purge() async throws { try await base.purge() }
    func recoverAbandonedRequests() async throws { try await base.recoverAbandonedRequests() }
    func authorizedSnapshot(for key: OfflineSnapshotKey) async throws -> EncryptedOfflineSnapshot? { try await base.authorizedSnapshot(for: key) }
    func hasAuthorizedSnapshot(for key: OfflineSnapshotKey) async throws -> Bool { try await base.hasAuthorizedSnapshot(for: key) }
    func isAuthorized(_ snapshot: EncryptedOfflineSnapshot) async throws -> Bool { try await base.isAuthorized(snapshot) }
    func discardCorruptSnapshot(_ snapshot: EncryptedOfflineSnapshot) async throws { try await base.discardCorruptSnapshot(snapshot) }
    func hasPersistedSnapshots() async throws -> Bool { try await base.hasPersistedSnapshots() }
    func offlineVaultIds() async throws -> Set<String> { try await base.offlineVaultIds() }
    func offlineItemSelection(itemId: String) async throws -> OfflineItemSelection? { try await base.offlineItemSelection(itemId: itemId) }
    func offlineItemSelections() async throws -> [OfflineItemSelection] { try await base.offlineItemSelections() }
}
extension IncrementalSyncRepository: OfflineSnapshotPersisting {}
