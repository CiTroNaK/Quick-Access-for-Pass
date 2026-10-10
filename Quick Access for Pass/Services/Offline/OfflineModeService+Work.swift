import Foundation

/// One metadata-only admission capability, never reusable across intents or preparations.
nonisolated struct OfflineSelectionPermit: Sendable {
    let operationID: UUID
    let observationGeneration: UUID
    let workGeneration: UUID
}

extension OfflineModeService {
    nonisolated enum WorkScope: Sendable {
        case all
        case vault(String)
        case item(String)

        func overlaps(_ other: Self) -> Bool {
            switch (self, other) {
            case (.all, _), (_, .all): true
            case (.vault(let lhs), .vault(let rhs)), (.item(let lhs), .item(let rhs)): lhs == rhs
            // Item permits also carry their vault separately in OwnedPermit.
            default: false
            }
        }

        func contains(_ key: OfflineSnapshotKey) -> Bool {
            switch self {
            case .all: true
            case .vault(let id): key.vaultId == id
            case .item(let id): key.itemId == id
            }
        }
    }

    nonisolated struct OwnedPermit: Sendable {
        let permit: OfflineSelectionPermit
        let scope: WorkScope
        let vaultID: String
    }

    nonisolated struct OwnedReservation: Sendable {
        let candidate: OfflineSnapshotWorkCandidate
        let request: OfflineRequestToken
    }

    var submissionsAllowed: Bool { ready && !stopped && !resetSuspended }
    var selectionAdmissionOpen: Bool { submissionsAllowed && observationIsFresh }

    func updateSelectionObservation(generation: UUID, status: OfflineSelectionObservationStatus) async {
        guard !Task.isCancelled, !stopped else { return }
        switch status {
        case .starting:
            observationGeneration = generation
            observationIsFresh = false
        case .fresh:
            guard observationGeneration == generation, ready else { return }
            observationIsFresh = true
        case .failed:
            guard observationGeneration == generation else { return }
            observationIsFresh = false
        }
    }

    /// Ephemeral repository metadata for one captured candidate, never a release
    /// authorization or reusable permit. Reservation still checks its generation.
    nonisolated private struct ManualWorkProof: Sendable {
        let key: OfflineSnapshotKey
        let selectionGeneration: UUID
    }

    /// Checking admission and recording ownership is one synchronous actor turn.
    private func grantPermit(scope: WorkScope, vaultID: String,
                             manualWork: ManualWorkProof? = nil) throws -> OfflineSelectionPermit {
        try requireReady()
        guard selectionAdmissionOpen, let observationGeneration,
              !isBlocked(scope: scope, vaultID: vaultID, manualWork: manualWork) else { throw Error.selectionSuspended }
        let permit = OfflineSelectionPermit(operationID: UUID(), observationGeneration: observationGeneration,
                                            workGeneration: workGeneration)
        permits[permit.operationID] = OwnedPermit(permit: permit, scope: scope, vaultID: vaultID)
        return permit
    }

    func releasePermit(_ permit: OfflineSelectionPermit) {
        guard permits.removeValue(forKey: permit.operationID) != nil else { return }
        let waiters = permitDrainWaiters
        permitDrainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func isBlocked(scope: WorkScope, vaultID: String, manualWork: ManualWorkProof? = nil) -> Bool {
        revocations.values.contains { revocation in
            if case .vault(let revokedVaultID) = revocation, revokedVaultID == vaultID,
               case .item(let itemID) = scope, let manualWork,
               manualWork.key.vaultId == vaultID, manualWork.key.itemId == itemID {
                // Deselection cannot revoke this independently selected generation.
                // Item/all revocations and ordinary policy mutations get no exemption.
                return false
            }
            return revocation.overlaps(scope) || revocation.overlaps(.vault(vaultID))
        }
    }

    private func manualWorkProof(for candidate: OfflineSnapshotWorkCandidate) async throws -> ManualWorkProof? {
        let generation: UUID
        switch candidate.intent {
        case .materialize(let selected), .refresh(let selected): generation = selected
        case .vaultMaterialize: return nil
        }
        guard let selection = try await repository.offlineItemSelection(itemId: candidate.key.itemId),
              selection.vaultId == candidate.key.vaultId, selection.isManuallySelected,
              selection.selectionGeneration == generation else { return nil }
        return ManualWorkProof(key: candidate.key, selectionGeneration: generation)
    }

    func ownedScheduler() -> OfflineSnapshotWorkScheduler {
        if let scheduler { return scheduler }
        let scheduler = OfflineSnapshotWorkScheduler { [weak self] candidate in
            guard let self else { throw OfflineSnapshotWorkScheduler.Failure.cancelled }
            do {
                try await self.run(candidate)
            } catch Error.selectionSuspended {
                throw OfflineSnapshotWorkScheduler.Failure.selectionSuspended
            } catch Error.requestSuperseded {
                throw OfflineSnapshotWorkScheduler.Failure.superseded
            }
        }
        self.scheduler = scheduler
        return scheduler
    }

    func makeAvailableOffline(item: PassItem, shareId: String) async throws {
        let permit = try grantPermit(scope: .item(item.id), vaultID: item.vaultId)
        let lifecycle = lifecycleGeneration
        let generation: UUID
        do {
            generation = try await repository.selectItemManually(itemID: item.id, vaultID: item.vaultId, shareID: shareId)
            releasePermit(permit)
        } catch {
            releasePermit(permit)
            throw Error.persistenceFailed
        }
        // A transient scoped revocation blocks new permits, not this already
        // committed intent joining its preserved generation-bound reservation.
        guard submissionsAllowed, lifecycleGeneration == lifecycle else { throw Error.requestSuperseded }
        let candidates = try await repository.workCandidates(vaultID: item.vaultId, includeNewSelections: true, refreshExisting: false)
        guard lifecycle == lifecycleGeneration, submissionsAllowed else { throw Error.requestSuperseded }
        // Cached manual intent needs no new preparation. A proven active vault
        // reservation may be joined only through its preserved selection generation.
        let key = OfflineSnapshotKey(vaultId: item.vaultId, itemId: item.id, schemaVersion: OfflineSnapshotLimits.schemaVersion)
        let candidate: OfflineSnapshotWorkCandidate?
        if let owned = reservations[key], owned.request.selectionGeneration == generation,
           owned.request.shareID == shareId, owned.request.metadataModifyTime == item.modifyTime,
           owned.request.itemType == item.itemType {
            candidate = owned.candidate
        } else {
            candidate = candidates.first { $0.key == key && $0.intent == .materialize(selectionGeneration: generation) }
        }
        guard let candidate else {
            guard try await repository.hasAuthorizedSnapshot(for: key) else { throw Error.requestSuperseded }
            return
        }
        submittedKeys.insert(candidate.key)
        do { try await ownedScheduler().submitAndWait(candidate) } catch let failure as OfflineSnapshotWorkScheduler.Failure {
            try Self.rethrowSchedulerFailure(failure)
        }
    }

    private static func rethrowSchedulerFailure(_ failure: OfflineSnapshotWorkScheduler.Failure) throws {
        switch failure {
        case .selectionSuspended: throw Error.selectionSuspended
        case .unavailable: throw Error.snapshotUnavailable
        case .superseded: throw Error.requestSuperseded
        case .cancelled: throw CancellationError()
        }
    }

    func selectWholeVault(_ selected: Bool, vaultID: String) async throws {
        if !selected {
            try await revoke(.vault(vaultID)) { [repository] in
                _ = try await repository.setVaultSelected(false, vaultID: vaultID)
            }
            return
        }
        let permit = try grantPermit(scope: .vault(vaultID), vaultID: vaultID)
        let lifecycle = lifecycleGeneration
        do {
            _ = try await repository.setVaultSelected(true, vaultID: vaultID)
            releasePermit(permit)
        } catch {
            releasePermit(permit)
            throw Error.persistenceFailed
        }
        guard lifecycle == lifecycleGeneration, permit.workGeneration == workGeneration, submissionsAllowed else { return }
        // Policy has committed. Scheduling failure leaves it selected/retryable,
        // never turns that confirmed mutation into a failed toggle.
        try? await submitCurrent(vaultID: vaultID, includeNew: true, refreshExisting: false)
    }

    func keepOfflineIndividually(_ item: PassItem) async throws {
        let permit = try grantPermit(scope: .item(item.id), vaultID: item.vaultId)
        defer { releasePermit(permit) }
        do { try await repository.keepItemOfflineIndividually(itemID: item.id, vaultID: item.vaultId) } catch { throw Error.persistenceFailed }
        // Promotion owns no secret work and preserves any existing reservation.
    }

    func retrySelectedCopies(vaultID: String?) async throws {
        try requireReady()
        try await submitCurrent(vaultID: vaultID, includeNew: selectionAdmissionOpen, refreshExisting: true)
    }

    func retryOfflineItem(itemID: String, vaultID: String) async throws -> OfflineItemRetryResult {
        try requireReady()
        let epoch = workGeneration
        let candidate: OfflineSnapshotWorkCandidate?
        do {
            candidate = try await repository.workCandidateForSelectedItem(itemID: itemID, vaultID: vaultID)
        } catch { throw Error.persistenceFailed }
        guard epoch == workGeneration,
              let candidate, candidate.key.itemId == itemID, candidate.key.vaultId == vaultID,
              submissionsAllowed, !Task.isCancelled,
              !isBlocked(scope: .item(itemID), vaultID: vaultID) else {
            return .unavailable
        }
        let current = reservationAwareCandidate(candidate)
        submittedKeys.insert(current.key)
        await ownedScheduler().submit([current])
        return .submitted
    }

    func metadataDidSynchronize(allowMembershipExpansion: Bool, eligibleItemIDs: Set<String>) async {
        guard submissionsAllowed, !Task.isCancelled, !eligibleItemIDs.isEmpty else { return }
        try? await submitCurrent(vaultID: nil,
                                 includeNew: allowMembershipExpansion && selectionAdmissionOpen,
                                 refreshExisting: true,
                                 eligibleItemIDs: eligibleItemIDs)
    }

    private func reservationAwareCandidate(_ candidate: OfflineSnapshotWorkCandidate) -> OfflineSnapshotWorkCandidate {
        guard let owned = reservations[candidate.key],
              candidate.shareID == owned.request.shareID,
              candidate.metadataModifyTime == owned.request.metadataModifyTime,
              candidate.itemType == owned.request.itemType else { return candidate }
        switch candidate.intent {
        case .materialize(let generation), .refresh(let generation):
            return generation == owned.request.selectionGeneration ? owned.candidate : candidate
        case .vaultMaterialize:
            return candidate
        }
    }

    func submitCurrent(vaultID: String?, includeNew: Bool, refreshExisting: Bool, eligibleItemIDs: Set<String>? = nil) async throws {
        guard submissionsAllowed else { return }
        let epoch = workGeneration
        let candidates: [OfflineSnapshotWorkCandidate]
        do {
            candidates = try await repository.workCandidates(vaultID: vaultID, includeNewSelections: includeNew,
                                                             refreshExisting: refreshExisting)
        } catch { throw Error.persistenceFailed }
        guard epoch == workGeneration, submissionsAllowed, !Task.isCancelled else { return }
        let current = candidates.filter { candidate in
            guard eligibleItemIDs.map({ $0.contains(candidate.key.itemId) }) ?? true else { return false }
            return !isBlocked(scope: .item(candidate.key.itemId), vaultID: candidate.key.vaultId)
        }.map(reservationAwareCandidate)
        submittedKeys.formUnion(current.map(\.key))
        await ownedScheduler().submit(current)
    }

    /// Recheck availability immediately before generation/version-bound reservation.
    func run(_ candidate: OfflineSnapshotWorkCandidate) async throws {
        try Task.checkCancellation()
        guard submissionsAllowed else { throw Error.selectionSuspended }
        let lifecycle = lifecycleGeneration
        let manualWork = try await manualWorkProof(for: candidate)
        try Task.checkCancellation()
        guard lifecycle == lifecycleGeneration, submissionsAllowed else { throw Error.requestSuperseded }
        guard !isBlocked(scope: .item(candidate.key.itemId), vaultID: candidate.key.vaultId,
                         manualWork: manualWork) else { throw Error.selectionSuspended }
        if case .refresh = candidate.intent {
            // Existing refresh needs readiness/current policy, never new admission.
        } else if try await repository.hasAuthorizedSnapshot(for: candidate.key) {
            return
        }
        guard lifecycle == lifecycleGeneration, submissionsAllowed,
              !isBlocked(scope: .item(candidate.key.itemId), vaultID: candidate.key.vaultId,
                         manualWork: manualWork) else { throw Error.requestSuperseded }
        let request = try await reserve(candidate, manualWork: manualWork)
        guard let request else { throw Error.requestSuperseded }
        reservations[candidate.key] = OwnedReservation(candidate: candidate, request: request)
        defer {
            if reservations[candidate.key]?.request.id == request.id { reservations.removeValue(forKey: candidate.key) }
        }
        guard lifecycle == lifecycleGeneration, submissionsAllowed, !Task.isCancelled else {
            await finish(request, failed: false)
            throw Error.requestSuperseded
        }
        try await prepareAndPublish(request: request, lifecycle: lifecycle)
    }

    private func reserve(
        _ candidate: OfflineSnapshotWorkCandidate, manualWork: ManualWorkProof?
    ) async throws -> OfflineRequestToken? {
        let kind: OfflineRequestKind
        let selectionGeneration: UUID?
        let permit: OfflineSelectionPermit?
        switch candidate.intent {
        case .refresh(let generation):
            kind = .refresh; selectionGeneration = generation; permit = nil
        case .materialize(let generation):
            kind = .materialization; selectionGeneration = generation
            permit = try grantPermit(scope: .item(candidate.key.itemId), vaultID: candidate.key.vaultId,
                                     manualWork: manualWork)
        case .vaultMaterialize(let generation):
            kind = .vaultSelection(policyGeneration: generation); selectionGeneration = nil
            permit = try grantPermit(scope: .item(candidate.key.itemId), vaultID: candidate.key.vaultId)
        }
        let request: OfflineRequestToken?
        do {
            request = try await repository.beginRequest(
                itemID: candidate.key.itemId, vaultID: candidate.key.vaultId, shareID: candidate.shareID, kind: kind,
                expectations: .init(
                    selectionGeneration: selectionGeneration,
                    metadataModifyTime: candidate.metadataModifyTime, itemType: candidate.itemType
                )
            )
            if let permit { releasePermit(permit) }
        } catch {
            if let permit { releasePermit(permit) }
            throw Error.snapshotUnavailable
        }
        return request
    }
}
