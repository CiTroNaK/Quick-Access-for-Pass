import Foundation

extension OfflineModeService {
    func waitUntilIdle() async { await scheduler?.waitUntilIdle() }

    func removeOfflineItem(itemId: String) async throws {
        try await revoke(.item(itemId)) { [repository] in try await repository.removeItem(itemId) }
    }

    func removeAllOfflineData() async throws {
        try await revoke(.all) { [repository] in try await repository.purge() }
    }

    /// A scope is blocked before yielding. Drain only short metadata ownership,
    /// never fetch lifetimes; revoke persisted authority before cancellation/join.
    func revoke(_ scope: WorkScope, mutation: @Sendable () async throws -> Void) async throws {
        let releaseScope: OfflineReleaseMutationScope
        switch scope {
        case .item(let id): releaseScope = .itemID(id)
        case .vault(let id): releaseScope = .vaultOnly(vaultID: id)
        case .all: releaseScope = .all
        }
        let authority = repository.releaseAuthority
        let admission = authority.beginMutation(releaseScope)
        defer { authority.finishMutation(admission, outcome: .admissionFinished) }
        let id = UUID()
        revocations[id] = scope
        workGeneration = UUID()
        if case .all = scope { lifecycleGeneration = UUID() }
        defer { revocations.removeValue(forKey: id) }
        while permits.values.contains(where: { scope.overlaps($0.scope) || scope.overlaps(.vault($0.vaultID)) }) {
            await withCheckedContinuation { permitDrainWaiters.append($0) }
        }
        // Only vault deselection needs survivor metadata. Capture it after
        // promotions drain and before mutation; read failure must delete nothing.
        // Conflicting admissions stay blocked throughout this transaction boundary.
        let survivors: Set<OfflineSnapshotKey>
        if case .vault(let vaultID) = scope {
            do {
                survivors = Set(try await repository.offlineItemSelections().filter {
                    $0.vaultId == vaultID && $0.isManuallySelected
                }.map {
                    OfflineSnapshotKey(vaultId: $0.vaultId, itemId: $0.itemId,
                                       schemaVersion: OfflineSnapshotLimits.schemaVersion)
                })
            } catch { throw Error.persistenceFailed }
        } else {
            survivors = []
        }
        do { try await mutation() } catch { throw Error.persistenceFailed }
        let scheduler = self.scheduler
        if case .all = scope {
            await scheduler?.invalidateAll()
            submittedKeys.removeAll()
            return
        }
        // Include metadata candidates as well as active reservations, so queued
        // vault-only jobs are invalidated even before they have selection rows.
        let knownKeys = Set(reservations.keys).union(submittedKeys)
        let revoked = Set(knownKeys.filter { scope.contains($0) && !survivors.contains($0) })
        await scheduler?.invalidate(revoked)
        submittedKeys.subtract(revoked)
    }

    func prepareForMetadataReset() async throws {
        resetSuspended = true
        try await removeAllOfflineData()
        // Purge/revocation commits immediately; clearing metadata waits for actual old frames.
        await waitForSyncOperations()
    }

    func finishMetadataReset() async {
        guard !stopped else { return }
        resetSuspended = false
        try? await submitCurrent(vaultID: nil, includeNew: selectionAdmissionOpen, refreshExisting: false)
    }

    func stop() async {
        stopped = true
        observationIsFresh = false
        workGeneration = UUID()
        lifecycleGeneration = UUID()
        stopAdmissionMarker()
        let task = initializationTask
        let scheduler = self.scheduler
        task?.cancel()
        if let task { _ = await task.result }
        while !permits.isEmpty { await withCheckedContinuation { permitDrainWaiters.append($0) } }
        await revokeSyncCaptureAuthority()
        await scheduler?.stop()
        await waitForSyncOperations()
        initializationTask = nil
        initializationAttemptID = nil
    }
}
