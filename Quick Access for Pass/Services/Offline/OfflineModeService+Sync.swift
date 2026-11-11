import Foundation
import os

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
                                                 sourceTimes: index.sourceTimes, allowMembershipExpansion: allowMembershipExpansion,
                                                 contentRefreshCandidates: index.contentRefreshCandidates)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            _ = try syncContextIsActive(capture)
            return
        }
        var batch: [OfflineSyncPublication] = []
        var bytes = 0
        var frame = OfflineSyncFrame(result: result, index: index, capture: capture,
                                     allowMembershipExpansion: allowMembershipExpansion)
        for candidate in work {
            guard try syncContextIsActive(capture) else { return }
            guard let publication = try await prepareSyncPublicationOrFinishFailure(candidate, frame: &frame) else { continue }
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
        _ work: OfflineSyncWork, frame: inout OfflineSyncFrame
    ) async throws -> OfflineSyncPublication? {
        do {
            return try await prepareSyncPublication(work, frame: &frame)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard try syncContextIsActive(frame.capture) else { return nil }
            try? await repository.finishSyncFailures([work], capture: frame.capture)
            return nil
        }
    }

    /// `frame.agreement` is per-vault, per-item-type evidence for unverified releases, scoped to this one sync frame:
    /// the first needed item of each type is read with `item view` and compared with its list body.
    /// A type never vouches for another, since list bodies carry different secret fields per type.
    private func prepareSyncPublication(
        _ work: OfflineSyncWork, frame: inout OfflineSyncFrame
    ) async throws -> OfflineSyncPublication? {
        let (result, index, capture) = (frame.result, frame.index, frame.capture)
        let item: CLIItem
        let source: OfflineSyncContentSource
        let provenance = result.contentProvenanceByVaultID[work.key.vaultId] ?? .unavailable
        let listed = index.itemIndices[work.key].map { result.items[$0].item }
        let agreementKey = "\(work.key.vaultId)|\(work.itemType.rawValue)"
        let reusesList = provenance == .completeJSONV1
            || (provenance == .unverifiedCompleteJSON && frame.agreement[agreementKey] == true)
        if reusesList, let listed {
            item = listed
            source = .syncList
        } else {
            // Recheck the original conditional ownership before an additional secret-facing fetch.
            // This is not a new scalar reservation and cannot adopt a newer Retry or selection.
            let current = try await repository.syncWork(capture: capture, metadataProofs: [work.key: work.metadataProof],
                                                        sourceTimes: index.sourceTimes,
                                                        allowMembershipExpansion: frame.allowMembershipExpansion,
                                                        contentRefreshCandidates: work.requiresContentRefresh ? [work.key] : [])
            guard current.contains(where: { OfflineSnapshotRepository.sameSyncWork(work, $0) }),
                  try syncContextIsActive(capture) else { return nil }
            item = try await cliService.viewItem(itemId: work.key.itemId, shareId: work.shareID)
            source = .liveFallback
            if provenance == .unverifiedCompleteJSON, frame.agreement[agreementKey] == nil, let listed {
                let agrees = Self.sameContent(listed, item)
                frame.agreement[agreementKey] = agrees
                if !agrees {
                    AppLogger.sync.notice("unverified CLI list content disagreed with item view; using item view for this vault and item type")
                }
            }
        }
        guard try syncContextIsActive(capture) else { return nil }
        if work.requiresContentRefresh {
            let policy = OfflineSnapshotContentPolicy.current
            guard !policy.needsRefresh(contentRevision: policy.satisfiedRevision(for: item), for: work.itemType) else { return nil }
        }
        let identity = OfflineSnapshotPreparationIdentity(key: work.key, shareID: work.shareID, itemType: work.itemType)
        let prepared = try await codec.prepareSnapshot(from: item, for: identity)
        guard prepared.snapshot.payload.count <= OfflineSyncPublicationLimits.ciphertextBytes else { throw OfflinePersistenceError.payloadTooLarge }
        guard try syncContextIsActive(capture) else { return nil }
        return OfflineSyncPublication(work: work, prepared: prepared, refreshedAt: Date(), source: source)
    }

    /// Canonical comparison of everything the snapshot codec can persist from either source.
    private static func sameContent(_ lhs: CLIItem, _ rhs: CLIItem) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let left = try? encoder.encode(lhs), let right = try? encoder.encode(rhs) else { return false }
        return left == right
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

/// One awaited sync frame's inputs and its per-sync agreement evidence. It lives only in the
/// caller-owned frame and is never retained by the service or submitted to the scheduler.
private struct OfflineSyncFrame {
    let result: CLISyncFetchResult
    let index: OfflineSyncResultIndex
    let capture: OfflineSyncCapture
    let allowMembershipExpansion: Bool
    var agreement: [String: Bool] = [:]
}
