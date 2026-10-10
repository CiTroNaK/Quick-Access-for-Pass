import Foundation
import Synchronization
import Testing
@testable import Quick_Access_for_Pass

@Suite("Offline release authority")
nonisolated struct OfflineReleaseAuthorityTests {
    private func key(_ itemID: String = "item", vaultID: String = "vault") -> OfflineSnapshotKey {
        OfflineSnapshotKey(vaultId: vaultID, itemId: itemID, schemaVersion: 1)
    }

    private func proof(
        key: OfflineSnapshotKey? = nil, manual: Bool = true,
        generation: UUID = UUID(), revision: UUID = UUID(), type: ItemType = .login,
        digest: Data = Data(repeating: 8, count: 32)
    ) -> OfflineReleaseProof {
        OfflineReleaseProof(
            identity: OfflineSnapshotIdentity(key: key ?? self.key(), revision: revision,
                                              keyFingerprint: Data(repeating: 7, count: 32)),
            selectionGeneration: generation, isManuallySelected: manual,
            itemType: type, ciphertextDigest: digest
        )
    }

    private func issue(_ authority: OfflineReleaseAuthority, _ proof: OfflineReleaseProof) throws -> OfflineReleaseCapability {
        let capture = authority.capture(for: proof.identity.key)
        try authority.bind(capture, proof: proof)
        return try authority.authorize(capture, proof: proof)
    }

    private func expectRevoked(_ capability: OfflineReleaseCapability) {
        #expect(throws: OfflineReleaseError.revoked) {
            try capability.withRelease(validating: { Issue.record("Revoked result validated") },
                                       effect: { Issue.record("Revoked result released") })
        }
    }

    @Test func removalRevokesAnIssuedCapability() throws {
        let authority = OfflineReleaseAuthority()
        let capability = try issue(authority, proof())
        let mutation = authority.beginMutation(.keys([key()]))
        authority.finishMutation(mutation, outcome: .committed(manualPromotions: []))
        expectRevoked(capability)
    }

    @Test func mutationBetweenCaptureAndAuthorizationCannotBeMissed() throws {
        let authority = OfflineReleaseAuthority()
        let capture = authority.capture(for: key())
        let original = proof()
        try authority.bind(capture, proof: original)
        let mutation = authority.beginMutation(.itemID("item"))
        authority.finishMutation(mutation, outcome: .rolledBack)
        #expect(throws: OfflineReleaseError.revoked) { try authority.authorize(capture, proof: original) }
    }

    @Test func pendingMutationBlocksIssuanceAndOverlappingCompletionDoesNotReopenAdmission() throws {
        let authority = OfflineReleaseAuthority()
        let first = authority.beginMutation(.all)
        let second = authority.beginMutation(.keys([key()]))
        authority.finishMutation(first, outcome: .rolledBack)
        let original = proof()
        let blocked = authority.capture(for: key())
        #expect(throws: OfflineReleaseError.revoked) { try authority.bind(blocked, proof: original) }
        authority.finishMutation(second, outcome: .rolledBack)
        let fresh = try issue(authority, original)
        #expect(try fresh.withRelease(validating: {}, effect: { "fresh" }) == "fresh")
        #expect(throws: OfflineReleaseError.revoked) { try authority.bind(blocked, proof: original) }
    }

    @Test func rollbackAllowsFreshCaptureWithoutRestoringOldCapability() throws {
        let authority = OfflineReleaseAuthority()
        let original = proof()
        let old = try issue(authority, original)
        let mutation = authority.beginMutation(.all)
        authority.finishMutation(mutation, outcome: .rolledBack)
        expectRevoked(old)
        #expect(try issue(authority, original).withRelease(validating: {}, effect: { 42 }) == 42)
    }

    @Test func unrelatedKeysAndLiveResultsRemainUsable() throws {
        let authority = OfflineReleaseAuthority()
        let survivor = try issue(authority, proof(key: key("other")))
        let mutation = authority.beginMutation(.keys([key()]))
        #expect(try survivor.withRelease(validating: {}, effect: { "other" }) == "other")
        let live = ResolvedSecret(value: "live", offlineCapability: nil)
        #expect(try live.release(validating: {}, effect: { $0 }) == "live")
        authority.finishMutation(mutation, outcome: .admissionFinished)
    }

    @Test func releaseIsSingleUseIncludingAnEffectThatThrows() throws {
        enum Failure: Error { case effect }
        let authority = OfflineReleaseAuthority()
        let capability = try issue(authority, proof())
        #expect(throws: Failure.effect) { try capability.withRelease(validating: {}, effect: { throw Failure.effect }) }
        #expect(throws: OfflineReleaseError.alreadyConsumed) { try capability.withRelease(validating: {}, effect: {}) }
    }

    @Test func validationFailureDoesNotInvokeEffectAndConsumesCapability() throws {
        enum Failure: Error { case lifecycle }
        let authority = OfflineReleaseAuthority()
        let capability = try issue(authority, proof())
        #expect(throws: Failure.lifecycle) {
            try capability.withRelease(validating: { throw Failure.lifecycle }, effect: { Issue.record("Released after failed guard") })
        }
        #expect(throws: OfflineReleaseError.alreadyConsumed) { try capability.withRelease(validating: {}, effect: {}) }
        let live = ResolvedSecret(value: "live", offlineCapability: nil)
        #expect(throws: Failure.lifecycle) {
            try live.release(validating: { throw Failure.lifecycle }, effect: { _ in Issue.record("Live skipped guard") })
        }
    }

    @Test func mapPreservesExactCapabilityAndSharedSingleUse() throws {
        let authority = OfflineReleaseAuthority()
        let capability = try issue(authority, proof())
        let mapped = ResolvedSecret(value: "action", offlineCapability: capability).map { String($0.prefix(3)) }
        #expect(mapped.offlineCapability === capability)
        #expect(try mapped.release(validating: {}, effect: { $0 }) == "act")
        #expect(throws: OfflineReleaseError.alreadyConsumed) { try capability.withRelease(validating: {}, effect: {}) }
    }

    @Test func registrationLifetimeFollowsCaptureAndCapabilityOwners() throws {
        let authority = OfflineReleaseAuthority()
        var capture: OfflineReleaseCapture? = authority.capture(for: key())
        #expect(authority.registrationCount == 1)
        let original = proof()
        try authority.bind(try #require(capture), proof: original)
        var capability: OfflineReleaseCapability? = try authority.authorize(try #require(capture), proof: original)
        capture = nil
        #expect(authority.registrationCount == 1)
        #expect(try capability?.withRelease(validating: {}, effect: { 7 }) == 7)
        capability = nil
        #expect(authority.registrationCount == 0)
        do { let transient = authority.capture(for: key()); withExtendedLifetime(transient) { #expect(authority.registrationCount == 1) } }
        #expect(authority.registrationCount == 0)
    }

    @Test func mutationDeinitClearsOnlyItsOwnMarkerWithoutPromotion() throws {
        let authority = OfflineReleaseAuthority()
        let original = proof(manual: false)
        let old = try issue(authority, original)
        let overlapping = authority.beginMutation(.keys([key()]))
        do {
            let abandoned = authority.beginMutation(.all)
            withExtendedLifetime(abandoned) { expectRevoked(old) }
        }
        let blocked = authority.capture(for: key())
        #expect(throws: OfflineReleaseError.revoked) { try authority.bind(blocked, proof: original) }
        authority.finishMutation(overlapping, outcome: .rolledBack)
        let fresh = try issue(authority, original)
        let deselect = authority.beginMutation(.vaultOnly(vaultID: "vault"))
        expectRevoked(fresh)
        authority.finishMutation(deselect, outcome: .admissionFinished)
    }

    @Test func proofChangesAreRejectedAtAuthorization() throws {
        let authority = OfflineReleaseAuthority()
        let original = proof()
        let variants = [
            proof(generation: original.selectionGeneration, revision: UUID()),
            proof(generation: UUID(), revision: original.identity.revision),
            proof(generation: original.selectionGeneration, revision: original.identity.revision, type: .note),
            proof(generation: original.selectionGeneration, revision: original.identity.revision, digest: Data(repeating: 9, count: 32)),
            proof(manual: false, generation: original.selectionGeneration, revision: original.identity.revision),
            OfflineReleaseProof(identity: OfflineSnapshotIdentity(key: key(), revision: original.identity.revision,
                                                                 keyFingerprint: Data(repeating: 6, count: 32)),
                                selectionGeneration: original.selectionGeneration, isManuallySelected: true,
                                itemType: .login, ciphertextDigest: original.ciphertextDigest)
        ]
        for changed in variants {
            let capture = authority.capture(for: key())
            try authority.bind(capture, proof: original)
            #expect(throws: OfflineReleaseError.revoked) { try authority.authorize(capture, proof: changed) }
        }
    }

    @Test func foreignHandlesAndWrongCaptureKeyAreRejected() throws {
        let owner = OfflineReleaseAuthority()
        let other = OfflineReleaseAuthority()
        let capture = owner.capture(for: key())
        #expect(throws: OfflineReleaseError.revoked) { try other.bind(capture, proof: proof()) }
        #expect(throws: OfflineReleaseError.revoked) { try owner.bind(capture, proof: proof(key: key("wrong"))) }
    }

    @Test func vaultDeselectionPreservesManualAndOtherVaultCapabilities() throws {
        let authority = OfflineReleaseAuthority()
        let manual = try issue(authority, proof())
        let vaultOnly = try issue(authority, proof(manual: false))
        let other = try issue(authority, proof(key: key(vaultID: "other"), manual: false))
        let mutation = authority.beginMutation(.vaultOnly(vaultID: "vault"))
        expectRevoked(vaultOnly)
        #expect(try manual.withRelease(validating: {}, effect: { true }))
        #expect(try other.withRelease(validating: {}, effect: { true }))
        authority.finishMutation(mutation, outcome: .committed(manualPromotions: []))
    }

    @Test func committedPromotionPreservesIssuedAndPreBindResultsThroughLaterDeselection() throws {
        let authority = OfflineReleaseAuthority()
        let original = proof(manual: false)
        let issued = try issue(authority, original)
        let unbound = authority.capture(for: key())
        let mutation = authority.beginMutation(.none)
        authority.finishMutation(mutation, outcome: .committed(manualPromotions: [
            OfflineManualPromotion(key: key(), selectionGeneration: original.selectionGeneration)
        ]))
        let deselect = authority.beginMutation(.vaultOnly(vaultID: "vault"))
        try authority.bind(unbound, proof: original)
        let prepared = try authority.authorize(unbound, proof: original)
        #expect(try issued.withRelease(validating: {}, effect: { true }))
        #expect(try prepared.withRelease(validating: {}, effect: { true }))
        authority.finishMutation(deselect, outcome: .committed(manualPromotions: []))
    }

    @Test func promotionCannotRestoreInvalidTokensOrPromoteDifferentGeneration() throws {
        let authority = OfflineReleaseAuthority()
        let original = proof(manual: false)
        let old = try issue(authority, original)
        let promotion = authority.beginMutation(.none)
        let deselect = authority.beginMutation(.vaultOnly(vaultID: "vault"))
        authority.finishMutation(promotion, outcome: .committed(manualPromotions: [
            OfflineManualPromotion(key: key(), selectionGeneration: original.selectionGeneration)
        ]))
        expectRevoked(old)
        authority.finishMutation(deselect, outcome: .committed(manualPromotions: []))
        let freshManual = try issue(authority, proof(generation: original.selectionGeneration, revision: original.identity.revision))
        #expect(try freshManual.withRelease(validating: {}, effect: { true }))
        let unbound = authority.capture(for: key())
        let unrelatedPromotion = authority.beginMutation(.none)
        authority.finishMutation(unrelatedPromotion, outcome: .committed(manualPromotions: [
            OfflineManualPromotion(key: key(), selectionGeneration: UUID())
        ]))
        let next = authority.beginMutation(.vaultOnly(vaultID: "vault"))
        #expect(throws: OfflineReleaseError.revoked) { try authority.bind(unbound, proof: original) }
        authority.finishMutation(next, outcome: .rolledBack)
    }

    @Test func rollbackDoesNotPublishManualPromotion() throws {
        let authority = OfflineReleaseAuthority()
        let original = proof(manual: false)
        let capability = try issue(authority, original)
        let promotion = authority.beginMutation(.none)
        authority.finishMutation(promotion, outcome: .rolledBack)
        let deselect = authority.beginMutation(.vaultOnly(vaultID: "vault"))
        expectRevoked(capability)
        authority.finishMutation(deselect, outcome: .rolledBack)
    }

    @Test func permissionAdditiveFinalProofMayAdvanceManualSelection() throws {
        let authority = OfflineReleaseAuthority()
        let original = proof(manual: false)
        let capture = authority.capture(for: key())
        try authority.bind(capture, proof: original)
        let promoted = proof(generation: original.selectionGeneration, revision: original.identity.revision)
        let capability = try authority.authorize(capture, proof: promoted)
        let deselect = authority.beginMutation(.vaultOnly(vaultID: "vault"))
        #expect(try capability.withRelease(validating: {}, effect: { true }))
        authority.finishMutation(deselect, outcome: .admissionFinished)
    }

    @Test func conditionalSnapshotDeletionMatchesExactBoundRevisionAndDigest() throws {
        let authority = OfflineReleaseAuthority()
        let original = proof()
        let target = try issue(authority, original)
        let newer = try issue(authority, proof())
        let changedBytes = try issue(authority, proof(generation: original.selectionGeneration,
                                                     revision: original.identity.revision, digest: Data(repeating: 9, count: 32)))
        let unbound = authority.capture(for: key())
        let deletion = authority.beginMutation(.snapshot(identity: original.identity, ciphertextDigest: original.ciphertextDigest))
        expectRevoked(target)
        #expect(try newer.withRelease(validating: {}, effect: { true }))
        #expect(try changedBytes.withRelease(validating: {}, effect: { true }))
        #expect(throws: OfflineReleaseError.revoked) { try authority.bind(unbound, proof: original) }
        authority.finishMutation(deletion, outcome: .rolledBack)
    }

    @Test func metadataPredicatesMatchOnlyEligibilityChanges() throws {
        let active = OfflineIncomingItemIdentity(vaultID: "vault", itemType: .login, isActive: true)
        let moved = OfflineIncomingItemIdentity(vaultID: "other", itemType: .login, isActive: true)
        let inactive = OfflineIncomingItemIdentity(vaultID: "vault", itemType: .login, isActive: false)
        let changedType = OfflineIncomingItemIdentity(vaultID: "vault", itemType: .note, isActive: true)
        let cases: [(OfflineReleaseMutationScope, Bool)] = [
            (.none, false), (.upsertItems([:]), false), (.upsertItems(["item": active]), false),
            (.upsertItems(["item": moved]), true), (.upsertItems(["item": inactive]), true),
            (.upsertItems(["item": changedType]), true), (.replaceItems([:]), true),
            (.replaceItems(["item": active]), false), (.replaceItems(["item": moved]), true),
            (.replaceItems(["item": inactive]), true), (.replaceItems(["item": changedType]), true),
            (.retainVaults(["vault"]), false), (.retainVaults(["other"]), true)
        ]
        for (scope, revoked) in cases {
            let authority = OfflineReleaseAuthority()
            let capability = try issue(authority, proof())
            let mutation = authority.beginMutation(scope)
            if revoked { expectRevoked(capability) }
            else { #expect(try capability.withRelease(validating: {}, effect: { true })) }
            authority.finishMutation(mutation, outcome: .committed(manualPromotions: []))
        }
    }

    @Test func replacementUncertaintyRetainsOnlyApplicableAbsentKeysAndDecodedItemsWin() throws {
        let matching = SyncItemPresenceUncertainty(vaultID: "vault", skippedItemIDs: ["item"], hasUnidentifiedSkippedItems: false)
        let unknown = SyncItemPresenceUncertainty(vaultID: "vault", skippedItemIDs: [], hasUnidentifiedSkippedItems: true)
        let otherItem = SyncItemPresenceUncertainty(vaultID: "vault", skippedItemIDs: ["other"], hasUnidentifiedSkippedItems: false)
        let otherVault = SyncItemPresenceUncertainty(vaultID: "other", skippedItemIDs: ["item"], hasUnidentifiedSkippedItems: true)
        let cases: [(Set<String>, [String: OfflineIncomingItemIdentity], [SyncItemPresenceUncertainty], Bool)] = [
            (["vault"], [:], [matching], false), (["vault"], [:], [unknown], false),
            (["vault"], [:], [otherItem], true), (["vault"], [:], [otherVault], true),
            ([], [:], [matching], true), (["vault"], [:], [], true),
            (["vault"], ["item": .init(vaultID: "other", itemType: .login, isActive: true)], [unknown], true),
            (["vault"], ["item": .init(vaultID: "vault", itemType: .note, isActive: true)], [matching], true),
            (["vault"], ["item": .init(vaultID: "vault", itemType: .login, isActive: false)], [unknown], true),
            (["vault"], ["item": .init(vaultID: "vault", itemType: .login, isActive: true)], [], false)
        ]
        for (vaults, items, uncertainties, revoked) in cases {
            let authority = OfflineReleaseAuthority()
            let bound = try issue(authority, proof())
            let unbound = authority.capture(for: key())
            let mutation = authority.beginMutation(.replaceMetadata(.init(vaultIDs: vaults, itemsByID: items, presenceUncertainties: uncertainties)))
            authority.finishMutation(mutation, outcome: .committed(manualPromotions: []))
            if revoked {
                expectRevoked(bound)
                #expect(throws: OfflineReleaseError.revoked) { try authority.bind(unbound, proof: proof()) }
            } else {
                #expect(try bound.withRelease(validating: {}, effect: { true }))
                try authority.bind(unbound, proof: proof())
            }
        }
    }

    @Test func unboundTypeConstraintsAreCompactStickyAndCheckedAtBind() throws {
        let authority = OfflineReleaseAuthority()
        let matching = authority.capture(for: key())
        let mismatched = authority.capture(for: key())
        let update = authority.beginMutation(.upsertItems(["item": .init(vaultID: "vault", itemType: .login, isActive: true)]))
        authority.finishMutation(update, outcome: .committed(manualPromotions: []))
        try authority.bind(matching, proof: proof())
        #expect(throws: OfflineReleaseError.revoked) { try authority.bind(mismatched, proof: proof(type: .note)) }
        let conflicted = authority.capture(for: key())
        let first = authority.beginMutation(.upsertItems(["item": .init(vaultID: "vault", itemType: .note, isActive: true)]))
        authority.finishMutation(first, outcome: .rolledBack)
        let second = authority.beginMutation(.upsertItems(["item": .init(vaultID: "vault", itemType: .login, isActive: true)]))
        authority.finishMutation(second, outcome: .committed(manualPromotions: []))
        #expect(throws: OfflineReleaseError.revoked) { try authority.bind(conflicted, proof: proof()) }
    }

    @Test func unboundVaultConstraintAllowsOnlyManualProofEvenAfterRollback() throws {
        let authority = OfflineReleaseAuthority()
        let manual = authority.capture(for: key())
        let vaultOnly = authority.capture(for: key())
        let mutation = authority.beginMutation(.vaultOnly(vaultID: "vault"))
        authority.finishMutation(mutation, outcome: .rolledBack)
        try authority.bind(manual, proof: proof())
        #expect(throws: OfflineReleaseError.revoked) { try authority.bind(vaultOnly, proof: proof(manual: false)) }
    }

}

extension OfflineReleaseAuthorityTests {
    @Test func unboundMembershipLossInvalidatesEvenWhenTheMutationRollsBack() throws {
        let scopes: [OfflineReleaseMutationScope] = [
            .keys([key()]), .itemID("item"), .all, .retainVaults([]), .replaceItems([:]),
            .upsertItems(["item": .init(vaultID: "other", itemType: .login, isActive: true)]),
            .upsertItems(["item": .init(vaultID: "vault", itemType: .login, isActive: false)])
        ]
        for scope in scopes {
            let authority = OfflineReleaseAuthority()
            let capture = authority.capture(for: key())
            let mutation = authority.beginMutation(scope)
            authority.finishMutation(mutation, outcome: .rolledBack)
            #expect(throws: OfflineReleaseError.revoked) { try authority.bind(capture, proof: proof()) }
        }
    }

    @Test func pendingTypeUpdateAllowsMatchingProofAndRejectsMismatchingProof() throws {
        let authority = OfflineReleaseAuthority()
        let mutation = authority.beginMutation(.upsertItems(["item": .init(vaultID: "vault", itemType: .login, isActive: true)]))
        let original = proof()
        let matching = authority.capture(for: key())
        try authority.bind(matching, proof: original)
        let capability = try authority.authorize(matching, proof: original)
        #expect(try capability.withRelease(validating: {}, effect: { true }))
        let mismatching = authority.capture(for: key())
        #expect(throws: OfflineReleaseError.revoked) { try authority.bind(mismatching, proof: proof(type: .note)) }
        authority.finishMutation(mutation, outcome: .committed(manualPromotions: []))
    }

    @Test func keyScopeIncludesSchemaWhileItemIDScopeIncludesEveryVault() throws {
        let authority = OfflineReleaseAuthority()
        let differentSchema = OfflineSnapshotKey(vaultId: "vault", itemId: "item", schemaVersion: 2)
        let otherVault = try issue(authority, proof(key: key(vaultID: "other")))
        let schemaSurvivor = try issue(authority, proof(key: differentSchema))
        let targeted = authority.beginMutation(.keys([key()]))
        #expect(try schemaSurvivor.withRelease(validating: {}, effect: { true }))
        authority.finishMutation(targeted, outcome: .rolledBack)
        let itemRemoval = authority.beginMutation(.itemID("item"))
        expectRevoked(otherVault)
        authority.finishMutation(itemRemoval, outcome: .committed(manualPromotions: []))
    }

    @Test func conditionalSnapshotDeletionDoesNotMatchDifferentFingerprintOrSchema() throws {
        let authority = OfflineReleaseAuthority()
        let original = proof()
        let otherFingerprint = OfflineReleaseProof(
            identity: OfflineSnapshotIdentity(key: key(), revision: original.identity.revision, keyFingerprint: Data(repeating: 1, count: 32)),
            selectionGeneration: original.selectionGeneration, isManuallySelected: true,
            itemType: .login, ciphertextDigest: original.ciphertextDigest
        )
        let fingerprintSurvivor = try issue(authority, otherFingerprint)
        let schemaSurvivor = try issue(authority, proof(key: .init(vaultId: "vault", itemId: "item", schemaVersion: 2),
                                                      generation: original.selectionGeneration, revision: original.identity.revision))
        let deletion = authority.beginMutation(.snapshot(identity: original.identity, ciphertextDigest: original.ciphertextDigest))
        #expect(try fingerprintSurvivor.withRelease(validating: {}, effect: { true }))
        #expect(try schemaSurvivor.withRelease(validating: {}, effect: { true }))
        authority.finishMutation(deletion, outcome: .admissionFinished)
    }

    @Test func captureAndCapabilityRetainAuthorityWithoutAReferenceCycle() throws {
        var authority: OfflineReleaseAuthority? = OfflineReleaseAuthority()
        weak let weakAuthority = authority
        var capture: OfflineReleaseCapture? = try #require(authority).capture(for: key())
        let original = proof()
        try authority?.bind(try #require(capture), proof: original)
        var capability = try authority?.authorize(try #require(capture), proof: original)
        authority = nil
        capture = nil
        #expect(weakAuthority != nil)
        #expect(try capability?.withRelease(validating: {}, effect: { true }) == true)
        capability = nil
        #expect(weakAuthority == nil)
    }

    @Test func duplicateSettlementCannotPublishLatePromotion() throws {
        let authority = OfflineReleaseAuthority()
        let original = proof(manual: false)
        let capability = try issue(authority, original)
        let promotion = authority.beginMutation(.none)
        authority.finishMutation(promotion, outcome: .rolledBack)
        authority.finishMutation(promotion, outcome: .committed(manualPromotions: [
            .init(key: key(), selectionGeneration: original.selectionGeneration)
        ]))
        let deselect = authority.beginMutation(.vaultOnly(vaultID: "vault"))
        expectRevoked(capability)
        authority.finishMutation(deselect, outcome: .committed(manualPromotions: []))
    }

    // Dedicated OS threads exercise the synchronous sink lock, not cooperative-pool blocking.
    @Test func competingInvalidationWaitsForBoundedReleaseAndThenRevokesOtherResult() throws {
        let authority = OfflineReleaseAuthority()
        let releasing = try issue(authority, proof())
        let waiting = try issue(authority, proof())
        let effectEntered = DispatchSemaphore(value: 0)
        let finishEffect = DispatchSemaphore(value: 0)
        let mutationAttempted = DispatchSemaphore(value: 0)
        let releaseDone = DispatchSemaphore(value: 0)
        let mutationDone = DispatchSemaphore(value: 0)
        let events = Mutex<[String]>([])
        let releaseThread = Thread {
            defer { releaseDone.signal() }
            do {
                try releasing.withRelease(validating: { events.withLock { $0.append("validated") } }, effect: {
                    effectEntered.signal()
                    finishEffect.wait()
                    events.withLock { $0.append("released") }
                })
            } catch { Issue.record("Unexpected release failure: \(error)") }
        }
        releaseThread.qualityOfService = .userInitiated
        releaseThread.start()
        effectEntered.wait()
        let mutationThread = Thread {
            mutationAttempted.signal()
            let mutation = authority.beginMutation(.all)
            events.withLock { $0.append("invalidated") }
            authority.finishMutation(mutation, outcome: .committed(manualPromotions: []))
            mutationDone.signal()
        }
        mutationThread.qualityOfService = .userInitiated
        mutationThread.start()
        mutationAttempted.wait()
        finishEffect.signal()
        releaseDone.wait()
        mutationDone.wait()
        #expect(events.withLock { $0 } == ["validated", "released", "invalidated"])
        expectRevoked(waiting)
    }
}
