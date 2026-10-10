import CryptoKit
import Foundation
import GRDB
import Dispatch
import Synchronization
import Testing
@testable import Quick_Access_for_Pass

@Suite("Offline release mutation ordering", .timeLimit(.minutes(1)))
struct OfflineReleaseMutationTests {
    private func selectedFixture(testing: OfflineMutationTesting? = nil) async throws -> OfflineLifecycleFixture {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item", "other"], offlineMutationTesting: testing)
        let service = fixture.service()
        try await initializeOfflineFixtureService(service)
        for item in fixture.items { try await service.makeAvailableOffline(item: item, shareId: "share") }
        return fixture
    }

    private func capability(_ repository: OfflineSnapshotRepository, itemID: String = "item") async throws -> OfflineReleaseCapability {
        let key = OfflineSnapshotKey(vaultId: "vault", itemId: itemID, schemaVersion: 1)
        let authority = repository.releaseAuthority
        let capture = authority.capture(for: key)
        let snapshot = try #require(try await repository.authorizedSnapshot(for: key))
        let proof = try #require(try await repository.releaseProof(for: snapshot))
        try authority.bind(capture, proof: proof)
        return try authority.authorize(capture, proof: proof)
    }

    @Test func repositoryRemovalInvalidatesFinalRelease() async throws {
        let fixture = try await selectedFixture()
        let second = OfflineSnapshotRepository(database: fixture.database)
        #expect(fixture.repository.releaseAuthority === fixture.database.offlineReleaseAuthority)
        #expect(second.releaseAuthority === fixture.repository.releaseAuthority)
        let release = try await capability(second)
        let unrelated = try await capability(second, itemID: "other")
        try await fixture.repository.removeItem("item")
        #expect(throws: OfflineReleaseError.revoked) { try release.withRelease(validating: {}, effect: { "must-not-release" }) }
        #expect(try unrelated.withRelease(validating: {}, effect: { true }))
    }

    @Test func repositoryPurgeInvalidatesFinalRelease() async throws {
        let fixture = try await selectedFixture()
        let release = try await capability(fixture.repository)
        try await fixture.repository.purge()
        #expect(throws: OfflineReleaseError.revoked) { try release.withRelease(validating: {}, effect: { true }) }
    }

    @Test func repositoryReplacementInvalidatesFinalRelease() async throws {
        let fixture = try await selectedFixture()
        let release = try await capability(fixture.repository)
        let request = try #require(try await fixture.repository.beginRequest(itemID: "item", vaultID: "vault", shareID: "share", kind: .refresh))
        let item = try offlineTestCLIItem(id: "item", vaultID: "vault", shareID: "share", password: "replacement")
        let snapshot = try await fixture.codec().prepareSnapshot(from: item, for: request)
        #expect(try await fixture.repository.publish(snapshot, for: request, refreshedAt: Date()))
        #expect(throws: OfflineReleaseError.revoked) { try release.withRelease(validating: {}, effect: { true }) }
    }
    private func vaultFixture(testing: OfflineMutationTesting? = nil) async throws -> OfflineLifecycleFixture {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item", "other"], offlineMutationTesting: testing)
        let service = fixture.service()
        try await initializeOfflineFixtureService(service)
        try await service.selectWholeVault(true, vaultID: "vault")
        await service.waitUntilIdle()
        return fixture
    }

    @Test(arguments: [false, true]) func committedPromotionPreservesOldCapabilityAcrossDeselection(useSelect: Bool) async throws {
        let fixture = try await vaultFixture()
        let survivor = try await capability(fixture.repository)
        let removed = try await capability(fixture.repository, itemID: "other")
        let before = try #require(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item"))
        if useSelect { _ = try await fixture.repository.selectItemManually(itemID: "item", vaultID: "vault", shareID: "share") }
        else { try await fixture.repository.keepItemOfflineIndividually(itemID: "item", vaultID: "vault") }
        let promoted = try #require(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item"))
        #expect(promoted.payload == before.payload)
        #expect(promoted.selection.selectionGeneration == before.selection.selectionGeneration)
        #expect(promoted.selection.isManuallySelected)
        _ = try await fixture.repository.setVaultSelected(false, vaultID: "vault")
        #expect(try survivor.withRelease(validating: {}, effect: { true }))
        #expect(throws: OfflineReleaseError.revoked) { try removed.withRelease(validating: {}, effect: { true }) }
        #expect(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item") == promoted)
    }

    @Test(arguments: ["upsertMove", "upsertState", "upsertType", "syncItems", "retainVaults", "clearAll", "clearMetadata", "syncMetadata", "synchronizeMetadata"])
    func metadataWritersRevokeAffectedCapabilities(writer: String) async throws {
        let fixture = try await selectedFixture()
        let release = try await capability(fixture.repository)
        switch writer {
        case "upsertMove":
            try fixture.database.upsertVaults([PassVault(id: "moved", name: "Moved", shareId: "other-share")])
            try fixture.database.upsertItems([metadata(vaultID: "moved")])
        case "upsertState": try fixture.database.upsertItems([metadata(state: "Trashed")])
        case "upsertType": try fixture.database.upsertItems([metadata(type: .note)])
        case "syncItems": try fixture.database.syncItems([])
        case "retainVaults": try fixture.database.removeVaultsNotIn([])
        case "clearAll": try fixture.database.clearAll()
        case "clearMetadata": try await fixture.database.clearMetadata()
        case "syncMetadata": _ = try fixture.database.syncMetadata(vaults: [], items: [], descriptors: [])
        default: _ = try await fixture.database.synchronizeMetadata(vaults: [], items: [], descriptors: [])
        }
        #expect(throws: OfflineReleaseError.revoked) { try release.withRelease(validating: {}, effect: { true }) }
    }

    private func metadata(vaultID: String = "vault", type: ItemType = .login, state: String = "Active") -> PassItem {
        PassItem(id: "item", vaultId: vaultID, title: "Changed title", itemType: type, subtitle: "", url: nil,
                 hasTOTP: false, state: state, createTime: .distantPast, modifyTime: .distantFuture, useCount: 0, lastUsedAt: nil)
    }

    @Test func unchangedMetadataAndLossyEnumerationPreserveBytesAndRelease() async throws {
        let fixture = try await selectedFixture()
        let release = try await capability(fixture.repository)
        let before = try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item")
        try fixture.database.upsertItems([metadata()])
        try fixture.database.recordUsage(itemId: "item")
        try fixture.database.upsertVaults([PassVault(id: "vault", name: "Renamed", shareId: "new-share")])
        _ = try await fixture.database.synchronizeMetadata(
            vaults: [PassVault(id: "vault", name: "Renamed", shareId: "new-share")], items: [], descriptors: [],
            presenceUncertainties: [SyncItemPresenceUncertainty(vaultID: "vault", skippedItemIDs: ["item", "other"], hasUnidentifiedSkippedItems: false)])
        #expect(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item") == before)
        #expect(try release.withRelease(validating: {}, effect: { true }))
    }

    @Test func failedPublicationRevokesOldCapabilityButRetainsUsableBytes() async throws {
        let fixture = try await selectedFixture()
        let request = try #require(try await fixture.repository.beginRequest(itemID: "item", vaultID: "vault", shareID: "share", kind: .refresh))
        let release = try await capability(fixture.repository)
        let before = try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item")
        let invalidRequest = OfflineRequestToken(id: UUID(), key: request.key, shareID: request.shareID, metadataModifyTime: request.metadataModifyTime, itemType: request.itemType, selectionGeneration: request.selectionGeneration)
        let item = try offlineTestCLIItem(id: "item", vaultID: "vault", shareID: "share", password: "new")
        let snapshot = try await fixture.codec().prepareSnapshot(from: item, for: request)
        #expect(try await fixture.repository.publish(snapshot, for: invalidRequest, refreshedAt: .now) == false)
        #expect(throws: OfflineReleaseError.revoked) { try release.withRelease(validating: {}, effect: { true }) }
        #expect(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item") == before)
        let fresh = try await capability(fixture.repository)
        #expect(try fresh.withRelease(validating: {}, effect: { true }))
    }

    @Test func corruptionDiscardIsPayloadConditionalAndPrecise() async throws {
        let fixture = try await selectedFixture()
        let key = OfflineSnapshotKey(vaultId: "vault", itemId: "item", schemaVersion: 1)
        let old = try #require(try await fixture.repository.authorizedSnapshot(for: key))
        let request = try #require(try await fixture.repository.beginRequest(itemID: "item", vaultID: "vault", shareID: "share", kind: .refresh))
        let item = try offlineTestCLIItem(id: "item", vaultID: "vault", shareID: "share", password: "new")
        let replacement = try await fixture.codec().prepareSnapshot(from: item, for: request)
        #expect(try await fixture.repository.publish(replacement, for: request, refreshedAt: .now))
        let release = try await capability(fixture.repository)
        let before = try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item")
        try await fixture.repository.discardCorruptSnapshot(old)
        #expect(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item") == before)
        #expect(try release.withRelease(validating: {}, effect: { true }))
        let current = try await capability(fixture.repository)
        try await fixture.repository.discardCorruptSnapshot(replacement)
        #expect(throws: OfflineReleaseError.revoked) { try current.withRelease(validating: {}, effect: { true }) }
    }

    @Test func rollbackRevokesOldProofAndAllowsFreshPersistedProof() async throws {
        let fixture = try await selectedFixture()
        let release = try await capability(fixture.repository)
        let before = try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item")
        #expect(throws: TestFailure.rollback) {
            _ = try fixture.database.syncMetadata(vaults: [], items: [], descriptors: [], beforeDescriptorWrite: { throw TestFailure.rollback })
        }
        #expect(throws: OfflineReleaseError.revoked) { try release.withRelease(validating: {}, effect: { true }) }
        #expect(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item") == before)
        let fresh = try await capability(fixture.repository)
        #expect(try fresh.withRelease(validating: {}, effect: { true }))
    }

    @Test(arguments: ["deselect", "remove", "purge", "discard", "reconcileVault", "reconcileItem", "reconcileMove"])
    func productionWritersRevokeAffectedRelease(writer: String) async throws {
        let fixture = try await vaultFixture()
        let release = try await capability(fixture.repository)
        // Capture before promotion: committed manual permission must reach an already-issued capability.
        let neighbor = try await capability(fixture.repository, itemID: "other")
        try await fixture.repository.keepItemOfflineIndividually(itemID: "other", vaultID: "vault")
        let neighborBefore = try #require(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "other"))
        #expect(neighborBefore.selection.isManuallySelected)
        let key = OfflineSnapshotKey(vaultId: "vault", itemId: "item", schemaVersion: 1)
        let snapshot = try #require(try await fixture.repository.authorizedSnapshot(for: key))
        switch writer {
        case "deselect": _ = try await fixture.repository.setVaultSelected(false, vaultID: "vault")
        case "remove": try await fixture.repository.removeItem("item")
        case "purge": try await fixture.repository.purge()
        case "discard": try await fixture.repository.discardCorruptSnapshot(snapshot)
        case "reconcileVault":
            _ = try await fixture.database.synchronizeMetadata(vaults: [], items: [], descriptors: [])
        case "reconcileItem":
            // Incomplete enumeration is not deletion evidence; complete enumeration below is.
            let retained = try await capability(fixture.repository)
            let before = try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item")
            _ = try await fixture.database.synchronizeMetadata(
                vaults: [PassVault(id: "vault", name: "Vault", shareId: "share")], items: [fixture.items[1]], descriptors: [],
                presenceUncertainties: [SyncItemPresenceUncertainty(vaultID: "vault", skippedItemIDs: ["item"], hasUnidentifiedSkippedItems: false)])
            #expect(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item") == before)
            #expect(try retained.withRelease(validating: {}, effect: { true }))
            _ = try await fixture.database.synchronizeMetadata(
                vaults: [PassVault(id: "vault", name: "Vault", shareId: "share")], items: [fixture.items[1]], descriptors: [])
        default:
            _ = try await fixture.database.synchronizeMetadata(
                vaults: [PassVault(id: "vault", name: "Vault", shareId: "share"), PassVault(id: "moved", name: "Moved", shareId: "moved-share")],
                items: [metadata(vaultID: "moved"), fixture.items[1]], descriptors: [])
        }
        #expect(throws: OfflineReleaseError.revoked) { try release.withRelease(validating: {}, effect: { true }) }
        #expect(try await fixture.repository.authorizedSnapshot(for: key) == nil)
        if writer == "purge" || writer == "reconcileVault" {
            // Parent deletion revokes manual consent too; purge revokes every selected item.
            #expect(throws: OfflineReleaseError.revoked) { try neighbor.withRelease(validating: {}, effect: { true }) }
            #expect(try await fixture.repository.offlineItemSelections().isEmpty)
            #expect(try await fixture.repository.offlineVaultIds().isEmpty)
            #expect(try await fixture.repository.hasPersistedSnapshots() == false)
            #expect(try await fixture.database.reader.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineItemExclusions") == 0
            })
        } else {
            #expect(try neighbor.withRelease(validating: {}, effect: { true }))
            #expect(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "other") == neighborBefore)
        }
        if writer == "remove" {
            #expect(try await fixture.repository.itemPolicy(itemID: "item", vaultID: "vault")?.isExcluded == true)
            let candidates = try await fixture.repository.workCandidates(vaultID: "vault", includeNewSelections: true, refreshExisting: false)
            #expect(candidates.contains { $0.key.itemId == "item" } == false)
            let policyGeneration = try #require(try await fixture.repository.itemPolicy(itemID: "item", vaultID: "vault")?.vaultSelection?.generation)
            #expect(try await fixture.repository.beginRequest(itemID: "item", vaultID: "vault", shareID: "share",
                kind: .vaultSelection(policyGeneration: policyGeneration)) == nil)
        } else if writer == "discard" {
            #expect(try await fixture.repository.offlineItemSelection(itemId: "item")?.cacheStatus == .unavailable)
        } else if writer == "reconcileMove" {
            let movedPolicy = try #require(try await fixture.repository.itemPolicy(itemID: "item", vaultID: "moved"))
            #expect(movedPolicy.isManuallySelected == false)
            #expect(movedPolicy.vaultSelection == nil)
            #expect(try await fixture.repository.workCandidateForSelectedItem(itemID: "item", vaultID: "moved") == nil)
        }
    }

    @Test func purgeClearsExclusionsAndRevokesManualSurvivor() async throws {
        let fixture = try await vaultFixture()
        try await fixture.repository.removeItem("item")
        try await fixture.repository.keepItemOfflineIndividually(itemID: "other", vaultID: "vault")
        let survivor = try await capability(fixture.repository, itemID: "other")
        #expect(try await fixture.database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineItemExclusions") == 1
        })
        try await fixture.repository.purge()
        #expect(throws: OfflineReleaseError.revoked) { try survivor.withRelease(validating: {}, effect: { true }) }
        #expect(try await fixture.repository.offlineItemSelections().isEmpty)
        #expect(try await fixture.repository.offlineVaultIds().isEmpty)
        #expect(try await fixture.repository.hasPersistedSnapshots() == false)
        #expect(try await fixture.database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineItemExclusions") == 0
        })
    }

    @Test(arguments: ["vault", "type", "move", "absent", "incomplete", "unchanged"], [false, true])
    func pendingPredicateBlocksAffectedReadsBeforeWriterSubmission(change: String, beforeBind: Bool) async throws {
        let gate = OfflineTestGate()
        let testing = OfflineMutationTesting(afterAdmission: { scope in
            switch scope {
            case .vaultOnly, .replaceMetadata: try? await gate.wait()
            default: break
            }
        })
        let fixture = try await vaultFixture(testing: testing)
        try await fixture.repository.keepItemOfflineIndividually(itemID: "other", vaultID: "vault")
        let survivor = try await capability(fixture.repository, itemID: "other")
        let authority = fixture.repository.releaseAuthority
        let key = OfflineSnapshotKey(vaultId: "vault", itemId: "item", schemaVersion: 1)
        let snapshot = try #require(try await fixture.repository.authorizedSnapshot(for: key))
        let before = try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item")
        let capture = authority.capture(for: key)
        let proof = try #require(try await fixture.repository.releaseProof(for: snapshot))
        var release: OfflineReleaseCapability?
        if !beforeBind {
            try authority.bind(capture, proof: proof)
            release = try authority.authorize(capture, proof: proof)
        }
        let incoming: [PassItem]
        switch change {
        case "type": incoming = [metadata(type: .note), fixture.items[1]]
        case "move": incoming = [metadata(vaultID: "moved"), fixture.items[1]]
        case "absent", "incomplete": incoming = [fixture.items[1]]
        default: incoming = fixture.items
        }
        let mutation = Task {
            if change == "vault" { _ = try await fixture.repository.setVaultSelected(false, vaultID: "vault") }
            else {
                _ = try await fixture.database.synchronizeMetadata(
                    vaults: [PassVault(id: "vault", name: "Vault", shareId: "share"), PassVault(id: "moved", name: "Moved", shareId: "moved")],
                    items: incoming, descriptors: [],
                    presenceUncertainties: change == "incomplete" ? [SyncItemPresenceUncertainty(vaultID: "vault", skippedItemIDs: ["item"], hasUnidentifiedSkippedItems: false)] : [])
            }
        }
        try await gate.waitUntilEntered()
        let destructive = change != "incomplete" && change != "unchanged"
        if beforeBind {
            if destructive { #expect(throws: OfflineReleaseError.revoked) { try authority.bind(capture, proof: proof) } }
            else {
                try authority.bind(capture, proof: proof)
                release = try authority.authorize(capture, proof: proof)
            }
        }
        if let release {
            if destructive { #expect(throws: OfflineReleaseError.revoked) { try release.withRelease(validating: {}, effect: { true }) } }
            else { #expect(try release.withRelease(validating: {}, effect: { true })) }
        }
        #expect(try survivor.withRelease(validating: {}, effect: { true }))
        #expect(try ResolvedSecret(value: "live", offlineCapability: nil).release(validating: {}, effect: { $0 }) == "live")
        #expect(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item") == before)
        await gate.open()
        try await mutation.value
        if change == "type" || !destructive {
            #expect(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item") == before)
        } else {
            #expect(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item") == nil)
        }
    }

    @Test func publicationHookRunsAfterAdmissionAndSettlementPrecedesCallerHook() async throws {
        let beforeHook = OfflineTestGate()
        let afterHook = OfflineTestGate()
        let fixture = try await selectedFixture()
        let repository = OfflineSnapshotRepository(database: fixture.database,
            beforePublication: { try? await beforeHook.wait() }, afterPublication: { try? await afterHook.wait() })
        let request = try #require(try await repository.beginRequest(itemID: "item", vaultID: "vault", shareID: "share", kind: .refresh))
        let old = try await capability(repository)
        let snapshot = try await fixture.codec().prepareSnapshot(from: offlineTestCLIItem(id: "item", vaultID: "vault", shareID: "share", password: "new"), for: request)
        let mutation = Task { try await repository.publish(snapshot, for: request, refreshedAt: .distantFuture) }
        try await beforeHook.waitUntilEntered()
        #expect(throws: OfflineReleaseError.revoked) { try old.withRelease(validating: {}, effect: { true }) }
        await beforeHook.open()
        try await afterHook.waitUntilEntered()
        let fresh = try await capability(repository)
        #expect(try fresh.withRelease(validating: {}, effect: { true }))
        mutation.cancel()
        await afterHook.open()
        #expect(try await mutation.value)
        let persisted = try #require(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item"))
        #expect(persisted.payload == snapshot.payload)
        #expect(persisted.selection.lastRefreshedAt == .distantFuture)
        #expect(persisted.pendingRequestID == nil)
    }

    @Test func cancelledBeforeSubmissionClearsOnlyItsMarker() async throws {
        let gate = OfflineTestGate()
        let fixture = try await selectedFixture(testing: OfflineMutationTesting(afterAdmission: { scope in
            if case .itemID = scope { try? await gate.wait() }
        }))
        let before = try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item")
        let old = try await capability(fixture.repository)
        let mutation = Task { try await fixture.repository.removeItem("item") }
        try await gate.waitUntilEntered()
        mutation.cancel()
        await gate.open()
        _ = await mutation.result
        #expect(throws: OfflineReleaseError.revoked) { try old.withRelease(validating: {}, effect: { true }) }
        #expect(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item") == before)
        let fresh = try await capability(fixture.repository)
        #expect(try fresh.withRelease(validating: {}, effect: { true }))
    }

    @Test(arguments: ["vault", "metadata", "type", "move", "reconcile"])
    func synchronousAdmissionPrecedesQueuedWriterAndPrebindProof(change: String) async throws {
        let admitted = MutationSignal()
        let fixture = try await vaultFixture(testing: OfflineMutationTesting(admissionMarker: { scope in
            switch scope {
            case .vaultOnly, .replaceMetadata: admitted.signal()
            default: break
            }
        }))
        try await fixture.repository.keepItemOfflineIndividually(itemID: "other", vaultID: "vault")
        let survivor = try await capability(fixture.repository, itemID: "other")
        let old = try await capability(fixture.repository)
        let key = OfflineSnapshotKey(vaultId: "vault", itemId: "item", schemaVersion: 1)
        let capture = fixture.repository.releaseAuthority.capture(for: key)
        let snapshot = try #require(try await fixture.repository.authorizedSnapshot(for: key))
        let proof = try #require(try await fixture.repository.releaseProof(for: snapshot))
        let writerGate = SynchronousMutationGate()
        let blocker = Task { try await fixture.database.writer.writeWithoutTransaction { _ in writerGate.wait() } }
        var mutation: Task<Void, any Error>?
        do {
            try await writerGate.waitUntilEntered()
            mutation = Task.detached {
                switch change {
                case "vault": _ = try await fixture.repository.setVaultSelected(false, vaultID: "vault")
                case "metadata", "type", "move":
                    let incoming = change == "metadata" ? [fixture.items[1]] : [self.metadata(vaultID: change == "move" ? "moved" : "vault", type: change == "type" ? .note : .login), fixture.items[1]]
                    _ = try fixture.database.syncMetadata(
                        vaults: [PassVault(id: "vault", name: "Vault", shareId: "share"), PassVault(id: "moved", name: "Moved", shareId: "moved")],
                        items: incoming, descriptors: [])
                default:
                    _ = try await fixture.database.synchronizeMetadata(
                        vaults: [PassVault(id: "vault", name: "Vault", shareId: "share")], items: [fixture.items[1]], descriptors: [])
                }
            }
            try await admitted.wait()
            #expect(throws: OfflineReleaseError.revoked) { try old.withRelease(validating: {}, effect: { true }) }
            #expect(throws: OfflineReleaseError.revoked) { try fixture.repository.releaseAuthority.bind(capture, proof: proof) }
            let during = fixture.repository.releaseAuthority.capture(for: key)
            #expect(throws: OfflineReleaseError.revoked) { try fixture.repository.releaseAuthority.bind(during, proof: proof) }
            #expect(try survivor.withRelease(validating: {}, effect: { true }))
            #expect(try ResolvedSecret(value: "live", offlineCapability: nil).release(validating: {}, effect: { $0 }) == "live")
            writerGate.open()
            try await blocker.value
            try await mutation?.value
            let freshNeighbor = try await capability(fixture.repository, itemID: "other")
            #expect(try freshNeighbor.withRelease(validating: {}, effect: { true }))
            if change == "type" {
                let fresh = try await capability(fixture.repository)
                #expect(try fresh.withRelease(validating: {}, effect: { true }))
            } else { #expect(try await fixture.repository.authorizedSnapshot(for: key) == nil) }
        } catch {
            mutation?.cancel()
            writerGate.open()
            _ = await blocker.result
            _ = await mutation?.result
            throw error
        }
    }

    @Test(arguments: ["commit", "rollback", "lateCancellation"], ["remove", "reconcile"])
    func writerOwnsPendingMarkerThroughActualSettlement(outcome: String, entry: String) async throws {
        let fixture = try await selectedFixture()
        let observer = SettlementObserver(rollsBack: outcome == "rollback")
        try await fixture.database.writer.writeWithoutTransaction { db in db.add(transactionObserver: observer, extent: .databaseLifetime) }
        let key = OfflineSnapshotKey(vaultId: "vault", itemId: "item", schemaVersion: 1)
        let snapshot = try #require(try await fixture.repository.authorizedSnapshot(for: key))
        let before = try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item")
        let proof = try #require(try await fixture.repository.releaseProof(for: snapshot))
        let old = try await capability(fixture.repository)
        let neighbor = try await capability(fixture.repository, itemID: "other")
        let neighborBefore = try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "other")
        let mutation = Task {
            if entry == "remove" { try await fixture.repository.removeItem("item") }
            else {
                _ = try await fixture.database.synchronizeMetadata(
                    vaults: [PassVault(id: "vault", name: "Vault", shareId: "share")], items: [fixture.items[1]], descriptors: [])
            }
        }
        do {
            try await observer.gate.waitUntilEntered()
            // SQL has run; the observer still blocks COMMIT/ROLLBACK return to the production writer.
            let during = fixture.repository.releaseAuthority.capture(for: key)
            #expect(throws: OfflineReleaseError.revoked) { try fixture.repository.releaseAuthority.bind(during, proof: proof) }
            #expect(throws: OfflineReleaseError.revoked) { try old.withRelease(validating: {}, effect: { true }) }
            #expect(try neighbor.withRelease(validating: {}, effect: { true }))
            #expect(try ResolvedSecret(value: "live", offlineCapability: nil).release(validating: {}, effect: { $0 }) == "live")
            if outcome == "lateCancellation" { mutation.cancel() }
            observer.gate.open()
            let result = await mutation.result
            try await fixture.database.writer.writeWithoutTransaction { db in db.remove(transactionObserver: observer) }
            #expect(observer.settlementCount == 1)
            if outcome == "rollback" {
                #expect(throws: (any Error).self) { try result.get() }
                #expect(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item") == before)
                let fresh = try await capability(fixture.repository)
                #expect(try fresh.withRelease(validating: {}, effect: { true }))
                #expect(throws: OfflineReleaseError.revoked) { try fixture.repository.releaseAuthority.bind(during, proof: proof) }
            } else {
                try result.get()
                #expect(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item") == nil)
            }
            #expect(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "other") == neighborBefore)
        } catch {
            mutation.cancel()
            observer.gate.open()
            _ = await mutation.result
            try await fixture.database.writer.writeWithoutTransaction { db in db.remove(transactionObserver: observer) }
            throw error
        }
    }

    @Test func overlappingUnsettledPromotionFailsClosedButKeepsFreshManualSurvivor() async throws {
        let deselectionGate = OfflineTestGate()
        let fixture = try await vaultFixture(testing: OfflineMutationTesting(afterAdmission: { scope in
            if case .vaultOnly = scope { try? await deselectionGate.wait() }
        }))
        let old = try await capability(fixture.repository)
        let before = try #require(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item"))
        let observer = SettlementObserver(rollsBack: false)
        try await fixture.database.writer.writeWithoutTransaction { db in db.add(transactionObserver: observer, extent: .databaseLifetime) }
        let promotion = Task { try await fixture.repository.keepItemOfflineIndividually(itemID: "item", vaultID: "vault") }
        try await observer.gate.waitUntilEntered()
        let deselection = Task { _ = try await fixture.repository.setVaultSelected(false, vaultID: "vault") }
        try await deselectionGate.waitUntilEntered()
        #expect(throws: OfflineReleaseError.revoked) { try old.withRelease(validating: {}, effect: { true }) }
        observer.gate.open()
        try await promotion.value
        try await fixture.database.writer.writeWithoutTransaction { db in db.remove(transactionObserver: observer) }
        await deselectionGate.open()
        try await deselection.value
        let after = try #require(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item"))
        #expect(after.payload == before.payload)
        #expect(after.selection.cacheStatus == before.selection.cacheStatus)
        #expect(after.selection.lastRefreshedAt == before.selection.lastRefreshedAt)
        #expect(after.selection.selectionGeneration == before.selection.selectionGeneration)
        #expect(after.selection.isManuallySelected)
        let fresh = try await capability(fixture.repository)
        #expect(try fresh.withRelease(validating: {}, effect: { true }))
    }

    @Test func rolledBackPromotionDoesNotPublishManualPermission() async throws {
        let fixture = try await vaultFixture()
        let old = try await capability(fixture.repository)
        let before = try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item")
        let observer = SettlementObserver(rollsBack: true)
        try await fixture.database.writer.writeWithoutTransaction { db in db.add(transactionObserver: observer, extent: .databaseLifetime) }
        let promotion = Task { try await fixture.repository.keepItemOfflineIndividually(itemID: "item", vaultID: "vault") }
        try await observer.gate.waitUntilEntered()
        observer.gate.open()
        await #expect(throws: (any Error).self) { try await promotion.value }
        try await fixture.database.writer.writeWithoutTransaction { db in db.remove(transactionObserver: observer) }
        #expect(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item") == before)
        _ = try await fixture.repository.setVaultSelected(false, vaultID: "vault")
        #expect(throws: OfflineReleaseError.revoked) { try old.withRelease(validating: {}, effect: { true }) }
        #expect(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item") == nil)
    }

    @Test func productionPromotionAndReconciliationPreserveManualSurvivorRelease() async throws {
        let fixture = try await vaultFixture()
        let old = try await capability(fixture.repository)
        let inherited = try await capability(fixture.repository, itemID: "other")
        let before = try #require(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item"))
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        _ = try await fixture.repository.selectItemManually(itemID: "item", vaultID: "vault", shareID: "share")
        _ = try await fixture.database.synchronizeMetadata(
            vaults: [PassVault(id: "vault", name: "Vault", shareId: "share")], items: fixture.items, descriptors: [])
        let request = try #require(try await fixture.repository.beginRequest(itemID: "item", vaultID: "vault", shareID: "share", kind: .refresh))
        try await fixture.repository.finishRequest(request, failed: true)
        _ = try await fixture.repository.setVaultSelected(false, vaultID: "vault")
        let after = try #require(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item"))
        #expect(after.payload == before.payload)
        #expect(after.selection.selectionGeneration == before.selection.selectionGeneration)
        #expect(after.selection.lastRefreshedAt == before.selection.lastRefreshedAt)
        #expect(after.selection.cacheStatus == .failed)
        #expect(after.selection.isManuallySelected)
        #expect(after.pendingRequestID == nil)
        #expect(try old.withRelease(validating: {}, effect: { true }))
        #expect(throws: OfflineReleaseError.revoked) { try inherited.withRelease(validating: {}, effect: { true }) }
    }

    @Test func refreshOwnershipFailureAndRecoveryDoNotRevokeUsablePayload() async throws {
        let fixture = try await selectedFixture()
        let old = try await capability(fixture.repository)
        let before = try #require(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item"))
        let request = try #require(try await fixture.repository.beginRequest(itemID: "item", vaultID: "vault", shareID: "share", kind: .refresh))
        try await fixture.repository.finishRequest(request, failed: true)
        try await fixture.repository.recoverAbandonedRequests()
        let after = try #require(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item"))
        #expect(after.payload == before.payload)
        #expect(after.selection.selectionGeneration == before.selection.selectionGeneration)
        #expect(after.selection.lastRefreshedAt == before.selection.lastRefreshedAt)
        #expect(after.selection.cacheStatus == .failed)
        #expect(after.pendingRequestID == nil)
        #expect(try old.withRelease(validating: {}, effect: { true }))
    }

    @Test func releaseProofBindsPayloadGenerationManualSelectionAndMetadataType() async throws {
        let fixture = try await selectedFixture()
        let key = OfflineSnapshotKey(vaultId: "vault", itemId: "item", schemaVersion: 1)
        let snapshot = try #require(try await fixture.repository.authorizedSnapshot(for: key))
        let proof = try #require(try await fixture.repository.releaseProof(for: snapshot))
        let selection = try #require(try await fixture.repository.offlineItemSelection(itemId: "item"))
        #expect(proof.identity == snapshot.identity)
        #expect(proof.selectionGeneration == selection.selectionGeneration)
        #expect(proof.isManuallySelected)
        #expect(proof.itemType == .login)
        #expect(proof.ciphertextDigest == Data(SHA256.hash(data: snapshot.payload)))
        let mismatched = EncryptedOfflineSnapshot(identity: snapshot.identity, payload: Data(repeating: 0, count: snapshot.payload.count))
        #expect(try await fixture.repository.releaseProof(for: mismatched) == nil)
    }

    @Test func cancelledAdmissionCannotClearAnotherPendingWriter() async throws {
        let firstGate = OfflineTestGate()
        let secondGate = OfflineTestGate()
        let count = Mutex(0)
        let fixture = try await selectedFixture(testing: OfflineMutationTesting(afterAdmission: { scope in
            guard case .itemID = scope else { return }
            let first = count.withLock { count in count += 1; return count == 1 }
            try? await (first ? firstGate : secondGate).wait()
        }))
        let key = OfflineSnapshotKey(vaultId: "vault", itemId: "item", schemaVersion: 1)
        let snapshot = try #require(try await fixture.repository.authorizedSnapshot(for: key))
        let proof = try #require(try await fixture.repository.releaseProof(for: snapshot))
        let first = Task { try await fixture.repository.removeItem("item") }
        try await firstGate.waitUntilEntered()
        let second = Task { try await fixture.repository.removeItem("item") }
        try await secondGate.waitUntilEntered()
        first.cancel()
        await firstGate.open()
        _ = await first.result
        let during = fixture.repository.releaseAuthority.capture(for: key)
        #expect(throws: OfflineReleaseError.revoked) { try fixture.repository.releaseAuthority.bind(during, proof: proof) }
        second.cancel()
        await secondGate.open()
        _ = await second.result
        let fresh = try await capability(fixture.repository)
        #expect(try fresh.withRelease(validating: {}, effect: { true }))
    }

    private enum TestFailure: Error { case rollback }

}

/// Waits on a private test queue, never blocking a cooperative executor to observe a signal.
private final class MutationSignal: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func signal() { semaphore.signal() }
    func wait() async throws {
        let success = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [semaphore] in
                continuation.resume(returning: semaphore.wait(timeout: .now() + 10) == .success)
            }
        }
        #expect(success)
        if !success { throw GateError.timedOut }
    }
    private enum GateError: Error { case timedOut }
}

private final class SynchronousMutationGate: Sendable {
    private let entered = MutationSignal()
    private let semaphore = DispatchSemaphore(value: 0)
    func wait() {
        entered.signal()
        #expect(semaphore.wait(timeout: .now() + 10) == .success)
    }
    func waitUntilEntered() async throws { try await entered.wait() }
    func open() { semaphore.signal() }
}

private final class SettlementObserver: TransactionObserver, Sendable {
    let gate = SynchronousMutationGate()
    private let rollsBack: Bool
    init(rollsBack: Bool) { self.rollsBack = rollsBack }
    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { true }
    func databaseDidChange(with event: DatabaseEvent) {}
    func databaseWillCommit() throws { if rollsBack { throw ObserverError.rollback } }
    private let settlements = Mutex(0)
    var settlementCount: Int { settlements.withLock { $0 } }
    func databaseDidCommit(_ db: Database) { settlements.withLock { $0 += 1 }; gate.wait() }
    func databaseDidRollback(_ db: Database) { settlements.withLock { $0 += 1 }; gate.wait() }
    private enum ObserverError: Error { case rollback }
}
