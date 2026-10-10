import Foundation
import Synchronization

/// Orders immutable mutation intent against single-use, bounded synchronous delivery.
/// No repository/key access, decoding, suspension, or reentrant callbacks may occur under this mutex.
nonisolated final class OfflineReleaseAuthority: Sendable {
    private struct CaptureRecord {
        let key: OfflineSnapshotKey
        var proof: OfflineReleaseProof?
        var isValid = true
        var isConsumed = false
        var requiresManualSelection = false
        var requiredItemType: ItemType?
        var committedPromotionGeneration: UUID?

        mutating func apply(_ scope: OfflineReleaseMutationScope) {
            guard isValid else { return }
            if let proof {
                if scope.matches(proof) { isValid = false }
                return
            }
            switch scope.preBindConstraint(for: key) {
            case .none:
                break
            case .invalidate:
                isValid = false
            case .requiresManualSelection:
                requiresManualSelection = true
            case .itemType(let type):
                if let requiredItemType, requiredItemType != type { isValid = false }
                else { requiredItemType = type }
            }
        }

        func advancingPromotion(_ proof: OfflineReleaseProof) -> OfflineReleaseProof {
            guard committedPromotionGeneration == proof.selectionGeneration else { return proof }
            return Self.manuallySelected(proof)
        }

        static func manuallySelected(_ proof: OfflineReleaseProof) -> OfflineReleaseProof {
            OfflineReleaseProof(identity: proof.identity, selectionGeneration: proof.selectionGeneration,
                                isManuallySelected: true, itemType: proof.itemType, ciphertextDigest: proof.ciphertextDigest)
        }
    }

    private struct State {
        var captures: [UUID: CaptureRecord] = [:]
        var pending: [UUID: OfflineReleaseMutationScope] = [:]
    }

    private let state = Mutex(State())

    func capture(for key: OfflineSnapshotKey) -> OfflineReleaseCapture {
        let id = UUID()
        state.withLock { state in
            var record = CaptureRecord(key: key)
            for scope in state.pending.values { record.apply(scope) }
            state.captures[id] = record
        }
        return OfflineReleaseCapture(authority: self, registrationID: id)
    }

    /// Associates initial repository evidence before any decoding, folding only committed permission gains.
    func bind(_ capture: OfflineReleaseCapture, proof: OfflineReleaseProof) throws {
        guard capture.authority === self else { throw OfflineReleaseError.revoked }
        try state.withLock { state in
            guard var record = state.captures[capture.registrationID], record.isValid,
                  !record.isConsumed else { throw OfflineReleaseError.revoked }
            let effective = record.advancingPromotion(proof)
            guard effective.identity.key == record.key,
                  !record.requiresManualSelection || effective.isManuallySelected,
                  record.requiredItemType == nil || record.requiredItemType == effective.itemType,
                  record.proof == nil || record.proof == effective,
                  !state.pending.values.contains(where: { $0.matches(effective) }) else {
                record.isValid = false
                state.captures[capture.registrationID] = record
                throw OfflineReleaseError.revoked
            }
            record.proof = effective
            state.captures[capture.registrationID] = record
        }
    }

    /// A final repository read must agree with the initial snapshot and selection identity.
    func authorize(_ capture: OfflineReleaseCapture, proof: OfflineReleaseProof) throws -> OfflineReleaseCapability {
        guard capture.authority === self else { throw OfflineReleaseError.revoked }
        try state.withLock { state in
            guard var record = state.captures[capture.registrationID], record.isValid,
                  !record.isConsumed, let initial = record.proof else { throw OfflineReleaseError.revoked }
            let effective = record.advancingPromotion(proof)
            guard initial.identity == effective.identity,
                  initial.ciphertextDigest == effective.ciphertextDigest,
                  initial.selectionGeneration == effective.selectionGeneration,
                  initial.itemType == effective.itemType,
                  !initial.isManuallySelected || effective.isManuallySelected,
                  !state.pending.values.contains(where: { $0.matches(effective) }) else {
                record.isValid = false
                state.captures[capture.registrationID] = record
                throw OfflineReleaseError.revoked
            }
            record.proof = effective
            state.captures[capture.registrationID] = record
        }
        return OfflineReleaseCapability(capture: capture)
    }

    /// Invalidation and independently owned pending admission share one linearization point.
    func beginMutation(_ scope: OfflineReleaseMutationScope) -> OfflineReleaseMutation {
        let id = UUID()
        state.withLock { state in
            for (captureID, var record) in state.captures {
                record.apply(scope)
                state.captures[captureID] = record
            }
            state.pending[id] = scope
        }
        return OfflineReleaseMutation(authority: self, registrationID: id)
    }

    func finishMutation(_ mutation: OfflineReleaseMutation, outcome: OfflineReleaseMutationOutcome) {
        guard mutation.authority === self else { return }
        state.withLock { state in
            guard state.pending[mutation.registrationID] != nil else { return }
            if case .committed(let promotions) = outcome {
                for promotion in promotions {
                    for (captureID, var record) in state.captures where record.key == promotion.key {
                        if let proof = record.proof {
                            if proof.selectionGeneration == promotion.selectionGeneration {
                                record.proof = CaptureRecord.manuallySelected(proof)
                                record.committedPromotionGeneration = promotion.selectionGeneration
                            }
                        } else {
                            // One generation only; no per-item history and no resurrection of invalid records.
                            record.committedPromotionGeneration = promotion.selectionGeneration
                        }
                        state.captures[captureID] = record
                    }
                }
            }
            state.pending.removeValue(forKey: mutation.registrationID)
        }
    }

    /// Validation and effect are synchronous/non-reentrant. Caller guards lifecycle/cancellation/deadline here,
    /// not before acquiring synchronization. Only the bounded sink effect may touch a secret under the lock.
    func withRelease<T>(
        _ capability: OfflineReleaseCapability, validating: () throws -> Void, effect: () throws -> T
    ) throws -> T {
        let capture = capability.capture
        guard capture.authority === self else { throw OfflineReleaseError.revoked }
        return try state.withLock { state in
            guard var record = state.captures[capture.registrationID], record.isValid,
                  let proof = record.proof else { throw OfflineReleaseError.revoked }
            guard !record.isConsumed else { throw OfflineReleaseError.alreadyConsumed }
            guard !state.pending.values.contains(where: { $0.matches(proof) }) else { throw OfflineReleaseError.revoked }
            record.isConsumed = true
            state.captures[capture.registrationID] = record
            try validating()
            return try effect()
        }
    }

    fileprivate func unregisterCapture(_ id: UUID) {
        _ = state.withLock { $0.captures.removeValue(forKey: id) }
    }

    fileprivate func abandonMutation(_ id: UUID) {
        // Defensive cleanup publishes no commit or promotion; invalidated captures remain invalid.
        _ = state.withLock { $0.pending.removeValue(forKey: id) }
    }

    #if DEBUG
    /// Test-only bounded ownership diagnostic; contains no catalog or secret data.
    var registrationCount: Int { state.withLock { $0.captures.count } }
    #endif
}

/// The authority stores value records, never these owners, so there is no retain cycle.
nonisolated final class OfflineReleaseCapture: Sendable {
    fileprivate let authority: OfflineReleaseAuthority
    fileprivate let registrationID: UUID

    fileprivate init(authority: OfflineReleaseAuthority, registrationID: UUID) {
        self.authority = authority
        self.registrationID = registrationID
    }

    deinit { authority.unregisterCapture(registrationID) }
}

nonisolated final class OfflineReleaseCapability: Sendable {
    fileprivate let capture: OfflineReleaseCapture

    fileprivate init(capture: OfflineReleaseCapture) { self.capture = capture }

    func withRelease<T>(validating: () throws -> Void, effect: () throws -> T) throws -> T {
        try capture.authority.withRelease(self, validating: validating, effect: effect)
    }
}

nonisolated final class OfflineReleaseMutation: Sendable {
    fileprivate let authority: OfflineReleaseAuthority
    fileprivate let registrationID: UUID

    fileprivate init(authority: OfflineReleaseAuthority, registrationID: UUID) {
        self.authority = authority
        self.registrationID = registrationID
    }

    deinit { authority.abandonMutation(registrationID) }
}
