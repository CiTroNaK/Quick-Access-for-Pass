import Foundation

extension OfflineModeService {
    /// The ordinary sync caller awaits this frame and its cleanup. Nothing secret-bearing is
    /// submitted to the scheduler or retained in the service's lifecycle registry.
    func consumeSyncResult(_ result: CLISyncFetchResult, capture: OfflineSyncCapture,
                           metadataProofs: [OfflineSnapshotKey: OfflineSyncedMetadataProof], allowMembershipExpansion: Bool) async throws {
        guard try beginSyncConsumption(capture) else { return }
        let index = OfflineSyncResultIndex(result)
        let work: [OfflineSyncWork]
        do {
            work = try await repository.syncWork(capture: capture, metadataProofs: metadataProofs,
                                                 sourceTimes: index.sourceTimes, allowMembershipExpansion: allowMembershipExpansion)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            _ = try syncContextIsActive(capture)
            return
        }
        var batch: [OfflineSyncPublication] = []
        var bytes = 0
        for candidate in work {
            guard try syncContextIsActive(capture) else { return }
            guard let publication = try await prepareSyncPublicationOrFinishFailure(
                candidate, result: result, index: index, capture: capture, allowMembershipExpansion: allowMembershipExpansion
            ) else { continue }
            let size = publication.prepared.snapshot.payload.count
            if batch.count == OfflineSyncPublicationLimits.items || size > OfflineSyncPublicationLimits.ciphertextBytes - bytes {
                guard try await flushSyncBatch(batch, capture: capture) else { return }
                batch.removeAll(keepingCapacity: true)
                bytes = 0
            }
            // At most one bounded ciphertext batch plus this single prepared result exists.
            batch.append(publication)
            bytes += size
        }
        if !batch.isEmpty { _ = try await flushSyncBatch(batch, capture: capture) }
    }

    private func prepareSyncPublicationOrFinishFailure(
        _ work: OfflineSyncWork, result: CLISyncFetchResult, index: OfflineSyncResultIndex,
        capture: OfflineSyncCapture, allowMembershipExpansion: Bool
    ) async throws -> OfflineSyncPublication? {
        do {
            return try await prepareSyncPublication(work, result: result, index: index,
                                                     capture: capture, allowMembershipExpansion: allowMembershipExpansion)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard try syncContextIsActive(capture) else { return nil }
            try? await repository.finishSyncFailures([work], capture: capture)
            return nil
        }
    }

    private func prepareSyncPublication(
        _ work: OfflineSyncWork, result: CLISyncFetchResult, index: OfflineSyncResultIndex,
        capture: OfflineSyncCapture, allowMembershipExpansion: Bool
    ) async throws -> OfflineSyncPublication? {
        let item: CLIItem
        let source: OfflineSyncContentSource
        if result.contentProvenanceByVaultID[work.key.vaultId] == .completeJSONV1, let position = index.itemIndices[work.key] {
            item = result.items[position].item
            source = .syncList
        } else {
            // Recheck the original conditional ownership before an additional secret-facing fetch.
            // This is not a new scalar reservation and cannot adopt a newer Retry or selection.
            let current = try await repository.syncWork(capture: capture, metadataProofs: [work.key: work.metadataProof],
                                                        sourceTimes: index.sourceTimes, allowMembershipExpansion: allowMembershipExpansion)
            guard current.contains(where: { OfflineSnapshotRepository.sameSyncWork(work, $0) }),
                  try syncContextIsActive(capture) else { return nil }
            item = try await cliService.viewItem(itemId: work.key.itemId, shareId: work.shareID)
            source = .liveFallback
        }
        guard try syncContextIsActive(capture) else { return nil }
        let identity = OfflineSnapshotPreparationIdentity(key: work.key, shareID: work.shareID, itemType: work.itemType)
        let prepared = try await codec.prepareSnapshot(from: item, for: identity)
        guard prepared.snapshot.payload.count <= OfflineSyncPublicationLimits.ciphertextBytes else { throw OfflinePersistenceError.payloadTooLarge }
        guard try syncContextIsActive(capture) else { return nil }
        return OfflineSyncPublication(work: work, prepared: prepared, refreshedAt: Date(), source: source)
    }

    private func flushSyncBatch(_ batch: [OfflineSyncPublication], capture: OfflineSyncCapture) async throws -> Bool {
        guard try syncContextIsActive(capture) else { return false }
        do {
            let published = try await repository.publishSyncBatch(batch, capture: capture)
            let rejected = batch.compactMap { published.contains($0.work.key) ? nil : $0.work }
            if !rejected.isEmpty { try? await repository.finishSyncFailures(rejected, capture: capture) }
            // Only still-owned rejected work can fail; committed/newer owners are never reversed.
            return true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard try syncContextIsActive(capture) else { return false }
            try? await repository.finishSyncFailures(batch.map(\.work), capture: capture)
            return true
        }
    }
}
