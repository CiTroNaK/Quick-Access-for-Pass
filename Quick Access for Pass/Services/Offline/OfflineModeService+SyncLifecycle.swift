import Foundation

extension OfflineModeService {
    /// Optional, pre-fetch admission. Failure never turns ordinary metadata sync into a failure.
    /// The all-scope permit spans only capture creation and joined late-return cleanup.
    func captureForSync(operation: SyncOperationToken) async -> OfflineSyncCapture? {
        guard selectionAdmissionOpen, operation.isCurrent, !Task.isCancelled,
              syncOperations[operation.id] == nil else { return nil }
        let permit: OfflineSelectionPermit
        do { permit = try grantSyncCapturePermit() } catch { return nil }
        let registrationID = UUID()
        let lifecycle = lifecycleGeneration
        syncOperations[operation.id] = OfflineSyncOperationRegistration(id: registrationID, lifecycleGeneration: lifecycle)
        do {
            let capture = try await repository.beginSyncCapture(operation: operation, lifecycleGeneration: lifecycle)
            guard submissionsAllowed, lifecycleGeneration == lifecycle, operation.isCurrent, !Task.isCancelled,
                  syncOperations[operation.id]?.id == registrationID else {
                await cleanupPersistedSyncCapture(capture)
                releasePermit(permit)
                finishSyncRegistration(operationID: operation.id, registrationID: registrationID)
                return nil
            }
            syncOperations[operation.id]?.capture = capture
            releasePermit(permit)
            return capture
        } catch {
            releasePermit(permit)
            finishSyncRegistration(operationID: operation.id, registrationID: registrationID)
            return nil
        }
    }

    /// Always joined by the caller on success, failure and cancellation. Cleanup contains only
    /// metadata and is detached solely so an already-cancelled caller can still finish the write.
    func finishSyncCapture(_ capture: OfflineSyncCapture) async {
        await cleanupPersistedSyncCapture(capture)
        guard let registration = syncOperations[capture.operation.id],
              registration.capture?.id == capture.id,
              registration.lifecycleGeneration == capture.lifecycleGeneration else { return }
        finishSyncRegistration(operationID: capture.operation.id, registrationID: registration.id)
    }

    func syncContextIsActive(_ capture: OfflineSyncCapture) throws -> Bool {
        try Task.checkCancellation()
        guard capture.operation.isCurrent else { throw CancellationError() }
        return submissionsAllowed && lifecycleGeneration == capture.lifecycleGeneration
            && syncOperations[capture.operation.id]?.capture?.id == capture.id
    }

    func beginSyncConsumption(_ capture: OfflineSyncCapture) throws -> Bool {
        guard try syncContextIsActive(capture),
              syncOperations[capture.operation.id]?.isConsuming == false else { return false }
        syncOperations[capture.operation.id]?.isConsuming = true
        return true
    }

    /// Stop closes in-memory admission first, drains short creation permits, revokes persisted
    /// capture authority, then joins caller-owned frames. It never retains their payload or Task.
    func revokeSyncCaptureAuthority() async {
        let captures = syncOperations.values.compactMap(\.capture)
        for capture in captures { await cleanupPersistedSyncCapture(capture) }
    }

    func waitForSyncOperations() async {
        while !syncOperations.isEmpty {
            await withCheckedContinuation { syncOperationDrainWaiters.append($0) }
        }
    }

    private func cleanupPersistedSyncCapture(_ capture: OfflineSyncCapture) async {
        let repository = repository
        let cleanup = Task.detached {
            // Durable rows are metadata-only; startup recovery retries abandonment if the store
            // is unavailable. In-memory lifecycle invalidation already blocks further submission.
            try? await repository.endSyncCapture(capture)
        }
        _ = await cleanup.value
    }

    private func finishSyncRegistration(operationID: UUID, registrationID: UUID) {
        guard syncOperations[operationID]?.id == registrationID else { return }
        syncOperations.removeValue(forKey: operationID)
        guard syncOperations.isEmpty else { return }
        let waiters = syncOperationDrainWaiters
        syncOperationDrainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
