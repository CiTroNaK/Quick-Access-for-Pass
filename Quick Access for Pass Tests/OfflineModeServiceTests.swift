import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("Offline mode lifecycle", .timeLimit(.minutes(1)))
struct OfflineModeServiceTests {
    @Test func initializationAloneDoesNotAdmitManualSelection() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let viewer = OfflineFixtureViewer()
        let service = fixture.service(viewer: viewer)
        try await service.initialize()
        let item = try #require(fixture.items.first)
        await #expect(throws: OfflineModeService.Error.selectionSuspended) {
            try await service.makeAvailableOffline(item: item, shareId: "share")
        }
        #expect(try await fixture.repository.offlineItemSelection(itemId: "item") == nil)
        #expect(await viewer.callCount(itemID: "item") == 0)
    }

    @Test func terminalObservationFailureBlocksAutomaticExpansion() async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["item"])
        let viewer = OfflineFixtureViewer()
        let service = f.service(viewer: viewer)
        try await service.initialize()
        let generation = UUID()
        await service.updateSelectionObservation(generation: generation, status: .starting)
        await service.updateSelectionObservation(generation: generation, status: .fresh)
        try await service.selectWholeVault(true, vaultID: "vault")
        await service.waitUntilIdle()
        await service.updateSelectionObservation(generation: generation, status: .failed)
        await #expect(throws: OfflineModeService.Error.selectionSuspended) {
            try await service.makeAvailableOffline(item: f.items[0], shareId: "share")
        }
        await #expect(throws: OfflineModeService.Error.selectionSuspended) {
            try await service.selectWholeVault(true, vaultID: "vault")
        }
        try f.database.upsertItems([offlineTestMetadata(id: "new", vaultID: "vault")])
        await service.metadataDidSynchronize(allowMembershipExpansion: true, eligibleItemIDs: Set(f.items.map(\.id)).union(["new"]))
        await service.waitUntilIdle()
        #expect(try await f.repository.offlineItemSelection(itemId: "new") == nil)
        #expect(await viewer.callCount(itemID: "new") == 0)
        let retryGeneration = UUID()
        await service.updateSelectionObservation(generation: retryGeneration, status: .starting)
        await service.updateSelectionObservation(generation: generation, status: .fresh)
        await service.metadataDidSynchronize(allowMembershipExpansion: true, eligibleItemIDs: Set(f.items.map(\.id)).union(["new"]))
        await service.waitUntilIdle()
        #expect(try await f.repository.offlineItemSelection(itemId: "new") == nil)
        #expect(await viewer.callCount(itemID: "new") == 0)
        await service.updateSelectionObservation(generation: retryGeneration, status: .fresh)
        try await service.retrySelectedCopies(vaultID: "vault")
        await service.waitUntilIdle()
        #expect(try await f.repository.offlineItemSelection(itemId: "new")?.cacheStatus == .cached)
        await service.stop()
    }

    @Test func bulkPolicyReturnsWhileOwnedFetchIsPausedAndFailureDoesNotRevokeIt() async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["item"])
        let gate = OfflineTestGate()
        let viewer = OfflineFixtureViewer(beforeView: { try await gate.wait() })
        let service = f.service(viewer: viewer)
        try await initializeOfflineFixtureService(service)
        try await service.selectWholeVault(true, vaultID: "vault")
        try await gate.waitUntilEntered()
        await service.updateSelectionObservation(generation: offlineFixtureObservationGeneration, status: .failed)
        await #expect(throws: OfflineModeService.Error.selectionSuspended) {
            try await service.keepOfflineIndividually(f.items[0])
        }
        await gate.open()
        await service.waitUntilIdle()
        #expect(try await f.repository.offlineItemSelection(itemId: "item")?.cacheStatus == .cached)
        #expect(await viewer.callCount(itemID: "item") == 1)
        try await service.selectWholeVault(false, vaultID: "vault")
        #expect(try await f.repository.offlineItemSelection(itemId: "item") == nil)
        await service.stop()
    }

    @Test func failedInitialBulkCopyRetainsVaultOriginOnRetry() async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["item"])
        let control = OfflineViewerFailureControl()
        let viewer = OfflineFixtureViewer(beforeView: { try await control.check() })
        let service = f.service(viewer: viewer)
        try await initializeOfflineFixtureService(service)
        try await service.selectWholeVault(true, vaultID: "vault")
        await service.waitUntilIdle()
        let failed = try #require(try await f.repository.offlineItemSelection(itemId: "item"))
        #expect(!failed.isManuallySelected && failed.cacheStatus == .unavailable)
        #expect(failed.lastRefreshedAt == nil)
        await control.succeed()
        try await service.retrySelectedCopies(vaultID: "vault")
        await service.waitUntilIdle()
        let retried = try #require(try await f.repository.offlineItemSelection(itemId: "item"))
        #expect(!retried.isManuallySelected && retried.cacheStatus == .cached)
        #expect(retried.selectionGeneration == failed.selectionGeneration)
        await service.stop()
    }

    @Test func promotionPreservesActiveVaultReservationAcrossDeselection() async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["item"])
        let gate = OfflineTestGate()
        let viewer = OfflineFixtureViewer(beforeView: { try await gate.wait() })
        let keys = OfflineFixtureKeys()
        let service = OfflineModeService(repository: f.repository, codec: f.codec(keys: keys), cliService: viewer)
        try await initializeOfflineFixtureService(service)
        try await service.selectWholeVault(true, vaultID: "vault")
        try await gate.waitUntilEntered()
        let before = try #require(try await f.repository.offlineItemSelection(itemId: "item"))
        let keyCalls = await keys.existingLookupCount()
        let keyCreates = await keys.createCount()
        try await service.keepOfflineIndividually(f.items[0])
        #expect(await keys.existingLookupCount() == keyCalls)
        #expect(await keys.createCount() == keyCreates)
        #expect(await viewer.callCount(itemID: "item") == 1)
        try await service.selectWholeVault(false, vaultID: "vault")
        await gate.open()
        await service.waitUntilIdle()
        let after = try #require(try await f.repository.offlineItemSelection(itemId: "item"))
        #expect(after.isManuallySelected && after.cacheStatus == .cached)
        #expect(after.selectionGeneration == before.selectionGeneration)
        #expect(await viewer.callCount(itemID: "item") == 1)
        let committed = try await OfflinePersistedTestState.capture(database: f.database, itemID: "item")
        let cachedKeyCalls = await keys.existingLookupCount()
        let cachedKeyCreates = await keys.createCount()
        try await service.keepOfflineIndividually(f.items[0])
        #expect(try await OfflinePersistedTestState.capture(database: f.database, itemID: "item") == committed)
        #expect(await keys.existingLookupCount() == cachedKeyCalls)
        #expect(await keys.createCount() == cachedKeyCreates)
        #expect(await viewer.callCount(itemID: "item") == 1)
        await service.stop()
    }

    @Test func failureBeforeInitialReservationNeverFetches() async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["item"])
        let candidatesGate = OfflineTestGate()
        let repository = RecoveryControlledRepository(base: f.repository, candidatesGate: candidatesGate)
        let viewer = OfflineFixtureViewer()
        let service = OfflineModeService(repository: repository, codec: f.codec(), cliService: viewer)
        try await initializeOfflineFixtureService(service)
        let selection = Task { try await service.selectWholeVault(true, vaultID: "vault") }
        try await candidatesGate.waitUntilEntered()
        await service.updateSelectionObservation(generation: offlineFixtureObservationGeneration, status: .failed)
        await candidatesGate.open()
        try await selection.value
        await service.waitUntilIdle()
        #expect(try await f.repository.offlineItemSelection(itemId: "item") == nil)
        #expect(await viewer.callCount(itemID: "item") == 0)
        await service.stop()
    }

    @Test func failureAfterPermitPreservesIntentButPurgeDrainsAndRevokesIt() async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["item"])
        let mutationGate = OfflineTestGate()
        let repository = RecoveryControlledRepository(base: f.repository, mutationGate: mutationGate)
        let viewer = OfflineFixtureViewer()
        let service = OfflineModeService(repository: repository, codec: f.codec(), cliService: viewer)
        try await initializeOfflineFixtureService(service)
        let manual = Task { try await service.makeAvailableOffline(item: f.items[0], shareId: "share") }
        try await mutationGate.waitUntilEntered()
        await service.updateSelectionObservation(generation: offlineFixtureObservationGeneration, status: .failed)
        await mutationGate.open()
        await #expect(throws: OfflineModeService.Error.selectionSuspended) { try await manual.value }
        #expect(try await f.repository.offlineItemSelection(itemId: "item")?.isManuallySelected == true)
        #expect(await viewer.callCount(itemID: "item") == 0)
        try await service.removeAllOfflineData()
        #expect(try await f.repository.offlineItemSelections().isEmpty)
        await service.stop()
    }

    @Test func manualJoinsProvenVaultReservationWithoutDuplicateFetch() async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["item"])
        let gate = OfflineTestGate()
        let viewer = OfflineFixtureViewer(beforeView: { try await gate.wait() })
        let service = f.service(viewer: viewer)
        try await initializeOfflineFixtureService(service)
        try await service.selectWholeVault(true, vaultID: "vault")
        try await gate.waitUntilEntered()
        let manual = Task { try await service.makeAvailableOffline(item: f.items[0], shareId: "share") }
        // Promotion is independently committed before deselection. The manual waiter
        // may start later; either path must join/skip this proven reservation.
        try await service.keepOfflineIndividually(f.items[0])
        try await service.selectWholeVault(false, vaultID: "vault")
        await gate.open()
        try await manual.value
        await service.waitUntilIdle()
        #expect(await viewer.callCount(itemID: "item") == 1)
        #expect(try await f.repository.offlineItemSelection(itemId: "item")?.isManuallySelected == true)
        await service.stop()
    }

    @Test func admittedManualJoinSurvivesConcurrentVaultDeselectionDrain() async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["item"])
        let fetchGate = OfflineTestGate()
        let mutationGate = OfflineTestGate()
        let repository = RecoveryControlledRepository(base: f.repository, mutationGate: mutationGate)
        let viewer = OfflineFixtureViewer(beforeView: { try await fetchGate.wait() })
        let service = OfflineModeService(repository: repository, codec: f.codec(), cliService: viewer)
        try await initializeOfflineFixtureService(service)
        try await service.selectWholeVault(true, vaultID: "vault")
        try await fetchGate.waitUntilEntered()
        let manual = Task { try await service.makeAvailableOffline(item: f.items[0], shareId: "share") }
        try await mutationGate.waitUntilEntered()
        try await service.deselectPausedFixtureIntent(gate: mutationGate)
        await fetchGate.open()
        do { try await manual.value }
        catch {
            print("Offline manual-join metadata trace: \(await repository.eventTrace())")
            throw error
        }
        await service.waitUntilIdle()
        #expect(await viewer.callCount(itemID: "item") == 1)
        #expect(try await f.repository.offlineItemSelection(itemId: "item")?.cacheStatus == .cached)
        await service.stop()
    }

    @Test(arguments: [false, true])
    func revocationDrainsAdmittedMutationBeforeDeleting(purge: Bool) async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["item"])
        let gate = OfflineTestGate()
        let repository = RecoveryControlledRepository(base: f.repository, mutationGate: gate)
        let viewer = OfflineFixtureViewer()
        let service = OfflineModeService(repository: repository, codec: f.codec(), cliService: viewer)
        try await initializeOfflineFixtureService(service)
        let manual = Task { try await service.makeAvailableOffline(item: f.items[0], shareId: "share") }
        try await gate.waitUntilEntered()
        try await service.revokePausedFixtureIntent(itemID: "item", purge: purge, gate: gate)
        _ = await manual.result
        await service.waitUntilIdle()
        #expect(try await f.repository.offlineItemSelection(itemId: "item") == nil)
        #expect(try await f.repository.hasPersistedSnapshots() == false)
        #expect(await viewer.callCount(itemID: "item") == 0)
        await service.stop()
    }

    @Test func observationFailureAfterReservationPermitDoesNotRevokeOwnedFetch() async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["item"])
        let gate = OfflineTestGate()
        let repository = RecoveryControlledRepository(base: f.repository, reservationGate: gate)
        let viewer = OfflineFixtureViewer()
        let service = OfflineModeService(repository: repository, codec: f.codec(), cliService: viewer)
        try await initializeOfflineFixtureService(service)
        try await service.selectWholeVault(true, vaultID: "vault")
        try await gate.waitUntilEntered()
        await service.updateSelectionObservation(generation: offlineFixtureObservationGeneration, status: .failed)
        await gate.open()
        await service.waitUntilIdle()
        #expect(try await f.repository.offlineItemSelection(itemId: "item")?.cacheStatus == .cached)
        #expect(await viewer.callCount(itemID: "item") == 1)
        await service.stop()
    }

}

extension OfflineModeServiceTests {
    @Test(arguments: [false, true])
    func queuedManualWorkSurvivesVaultDeselection(materializeFifth: Bool) async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["a", "b", "c", "d", "e"])
        let seeded = f.service()
        try await initializeOfflineFixtureService(seeded)
        for item in f.items where item.id != "e" || !materializeFifth {
            try await seeded.makeAvailableOffline(item: item, shareId: "share")
        }
        if materializeFifth {
            _ = try await f.repository.selectItemManually(itemID: "e", vaultID: "vault", shareID: "share")
        }
        _ = try await f.repository.setVaultSelected(true, vaultID: "vault")
        let before = try #require(try await f.repository.offlineItemSelection(itemId: "e"))
        let originalSnapshot = try await OfflinePersistedTestState.capture(database: f.database, itemID: "e")
        await seeded.stop()

        let fetchGates = Dictionary(uniqueKeysWithValues: f.items.map { ($0.id, OfflineTestGate()) })
        let deselectionGate = OfflineTestGate()
        let repository = RecoveryControlledRepository(base: f.repository, deselectionGate: deselectionGate)
        let viewer = OfflineFixtureViewer(beforeViewItem: { id in try await fetchGates[id]?.wait() })
        let service = OfflineModeService(repository: repository, codec: f.codec(), cliService: viewer)
        try await initializeOfflineFixtureService(service)
        await service.metadataDidSynchronize(allowMembershipExpansion: true, eligibleItemIDs: Set(f.items.map(\.id)))
        var deselection: Task<Void, Swift.Error>?
        do {
            for id in ["a", "b", "c", "d"] { try await fetchGates[id]?.waitUntilEntered() }
            #expect(await viewer.callCount(itemID: "e") == 0)
            deselection = Task { try await service.selectWholeVault(false, vaultID: "vault") }
            try await deselectionGate.waitUntilEntered()
            // The scheduler starts its fifth job while the policy mutation is
            // still suspended. Opening all fetch gates avoids a fifth-start wait
            // that would hang on RED when the old runner silently discards it.
            await fetchGates["a"]?.open()
            for id in ["b", "c", "d", "e"] { await fetchGates[id]?.open() }
            await service.waitUntilIdle()
            #expect(await viewer.callCount(itemID: "e") == 1)
            let refreshed = try #require(try await f.repository.offlineItemSelection(itemId: "e"))
            #expect(refreshed.isManuallySelected && refreshed.cacheStatus == .cached)
            #expect(refreshed.selectionGeneration == before.selectionGeneration)
            let snapshot = try #require(try await OfflinePersistedTestState.capture(database: f.database, itemID: "e"))
            #expect(snapshot.revision != originalSnapshot?.revision)
            #expect(try await f.repository.offlineVaultIds() == ["vault"])
            await deselectionGate.open()
            try await deselection?.value
            #expect(try await f.repository.offlineVaultIds().isEmpty)
            #expect(try await f.repository.offlineItemSelections().count == 5)
        } catch {
            deselection?.cancel()
            await deselectionGate.open()
            for gate in fetchGates.values { await gate.open() }
            if let deselection { _ = await deselection.result }
            await service.stop()
            throw error
        }
        await service.stop()
    }

    @Test(arguments: [false, true])
    func itemOrGlobalRevocationStillRevokesQueuedManualWorkDuringVaultDeselection(purge: Bool) async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["a", "b", "c", "d", "e"])
        let seeded = f.service()
        try await initializeOfflineFixtureService(seeded)
        for item in f.items { try await seeded.makeAvailableOffline(item: item, shareId: "share") }
        _ = try await f.repository.setVaultSelected(true, vaultID: "vault")
        await seeded.stop()
        let fetchGates = Dictionary(uniqueKeysWithValues: f.items.map { ($0.id, OfflineTestGate()) })
        let deselectionGate = OfflineTestGate()
        let repository = RecoveryControlledRepository(base: f.repository, deselectionGate: deselectionGate)
        let viewer = OfflineFixtureViewer(beforeViewItem: { id in try await fetchGates[id]?.wait() })
        let service = OfflineModeService(repository: repository, codec: f.codec(), cliService: viewer)
        try await initializeOfflineFixtureService(service)
        await service.metadataDidSynchronize(allowMembershipExpansion: false, eligibleItemIDs: Set(f.items.map(\.id)))
        var deselection: Task<Void, Swift.Error>?
        do {
            for id in ["a", "b", "c", "d"] { try await fetchGates[id]?.waitUntilEntered() }
            deselection = Task { try await service.selectWholeVault(false, vaultID: "vault") }
            try await deselectionGate.waitUntilEntered()
            if purge { try await service.removeAllOfflineData() }
            else { try await service.removeOfflineItem(itemId: "e") }
            for gate in fetchGates.values { await gate.open() }
            await service.waitUntilIdle()
            #expect(await viewer.callCount(itemID: "e") == 0)
            #expect(try await f.repository.offlineItemSelection(itemId: "e") == nil)
            #expect(try await OfflinePersistedTestState.capture(database: f.database, itemID: "e") == nil)
            await deselectionGate.open()
            try await deselection?.value
        } catch {
            deselection?.cancel()
            await deselectionGate.open()
            for gate in fetchGates.values { await gate.open() }
            if let deselection { _ = await deselection.result }
            await service.stop()
            throw error
        }
        await service.stop()
    }

}

extension OfflineModeServiceTests {
    @Test func scopedRemovalDoesNotCancelReservedSibling() async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["a", "b"])
        let recorder = OfflineWorkRecorder()
        let viewer = OfflineFixtureViewer(beforeViewItem: { id in try await recorder.run(serviceTestCandidate(id)) })
        let service = f.service(viewer: viewer)
        try await initializeOfflineFixtureService(service)
        try await service.selectWholeVault(true, vaultID: "vault")
        try await recorder.waitForStartedCount(2)
        try await service.removeOfflineItem(itemId: "a")
        #expect(await recorder.activeCount() == 1)
        await recorder.releaseAll()
        await service.waitUntilIdle()
        #expect(try await f.repository.offlineItemSelection(itemId: "a") == nil)
        #expect(try await f.repository.offlineItemSelection(itemId: "b")?.cacheStatus == .cached)
        await service.stop()
    }

    @Test func overlappingServiceTriggersShareFourSlotsAndOneFetch() async throws {
        let f = try OfflineLifecycleFixture(itemIDs: (0..<8).map { "item-\($0)" })
        let recorder = OfflineWorkRecorder()
        let viewer = OfflineFixtureViewer(beforeViewItem: { id in try await recorder.run(serviceTestCandidate(id)) })
        let service = f.service(viewer: viewer)
        try await initializeOfflineFixtureService(service)
        try await service.selectWholeVault(true, vaultID: "vault")
        try await recorder.waitForStartedCount(4)
        try await service.retrySelectedCopies(vaultID: "vault")
        await service.metadataDidSynchronize(allowMembershipExpansion: true, eligibleItemIDs: Set(f.items.map(\.id)))
        #expect(await recorder.maximumActiveCount() == 4)
        await recorder.releaseAll()
        await service.waitUntilIdle()
        #expect(await recorder.startedCount() == 8)
        #expect(await recorder.maximumCallsPerKey() == 1)
        #expect(try await f.repository.offlineItemSelections().allSatisfy { $0.cacheStatus == .cached })
        await service.stop()
    }

    @Test func queuedMaterializationSkipsNewlyCommittedSnapshot() async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["a", "b", "c", "d", "e"])
        let recorder = OfflineWorkRecorder()
        let viewer = OfflineFixtureViewer(beforeViewItem: { id in try await recorder.run(serviceTestCandidate(id)) })
        let service = f.service(viewer: viewer)
        try await initializeOfflineFixtureService(service)
        try await service.selectWholeVault(true, vaultID: "vault")
        try await recorder.waitForStartedCount(4)
        let request = try #require(try await f.repository.beginRequest(itemID: "e", vaultID: "vault", shareID: "share", kind: .selection))
        let snapshot = try await f.codec().prepareSnapshot(from: offlineTestCLIItem(id: "e", vaultID: "vault", shareID: "share", password: "fixture"), for: request)
        #expect(try await f.repository.publish(snapshot, for: request, refreshedAt: .now))
        await recorder.releaseAll()
        await service.waitUntilIdle()
        #expect(await viewer.callCount(itemID: "e") == 0)
        #expect(try await f.repository.offlineItemSelection(itemId: "e")?.cacheStatus == .cached)
        await service.stop()
    }

    @Test func obsoleteQueuedMetadataCannotFetchAndCurrentReplacementCan() async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["a", "b", "c", "d", "e"])
        let recorder = OfflineWorkRecorder()
        let viewer = OfflineFixtureViewer(beforeViewItem: { id in try await recorder.run(serviceTestCandidate(id)) })
        let service = f.service(viewer: viewer)
        try await initializeOfflineFixtureService(service)
        try await service.selectWholeVault(true, vaultID: "vault")
        try await recorder.waitForStartedCount(4)
        try f.database.upsertItems([offlineTestMetadata(id: "e", vaultID: "vault", modifyTime: Date(timeIntervalSince1970: 3))])
        await recorder.releaseAll()
        await service.waitUntilIdle()
        #expect(await viewer.callCount(itemID: "e") == 0)
        #expect(try await f.repository.offlineItemSelection(itemId: "e") == nil)
        await service.metadataDidSynchronize(allowMembershipExpansion: true, eligibleItemIDs: Set(f.items.map(\.id)))
        await service.waitUntilIdle()
        #expect(await viewer.callCount(itemID: "e") == 1)
        #expect(try await f.repository.offlineItemSelection(itemId: "e")?.cacheStatus == .cached)
        await service.stop()
    }

    @Test func metadataResetAndStopJoinWorkAndDoNotReopenPermanentlyStoppedService() async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["item"])
        let gate = OfflineTestGate()
        let viewer = OfflineFixtureViewer(beforeView: { try await gate.wait() })
        let service = f.service(viewer: viewer)
        try await initializeOfflineFixtureService(service)
        try await service.selectWholeVault(true, vaultID: "vault")
        try await gate.waitUntilEntered()
        try await service.prepareForMetadataReset()
        #expect(try await f.repository.offlineItemSelections().isEmpty)
        await #expect(throws: OfflineModeService.Error.selectionSuspended) {
            try await service.makeAvailableOffline(item: f.items[0], shareId: "share")
        }
        await gate.open()
        await service.finishMetadataReset()
        try await service.makeAvailableOffline(item: f.items[0], shareId: "share")
        await service.stop()
        await service.finishMetadataReset()
        await #expect(throws: OfflineModeService.Error.selectionSuspended) {
            try await service.makeAvailableOffline(item: f.items[0], shareId: "share")
        }
    }

    @Test func committedWholeVaultPolicySucceedsWhenSchedulingQueryFails() async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["item"])
        let repository = RecoveryControlledRepository(base: f.repository)
        let viewer = OfflineFixtureViewer()
        let service = OfflineModeService(repository: repository, codec: f.codec(), cliService: viewer)
        try await initializeOfflineFixtureService(service)
        await repository.failCandidateQueries(true)
        do { try await service.selectWholeVault(true, vaultID: "vault") }
        catch { Issue.record("Committed whole-vault policy must not be reported as a failed toggle") }
        #expect(try await f.repository.offlineVaultIds() == ["vault"])
        #expect(try await f.repository.offlineItemSelections().isEmpty)
        #expect(await viewer.callCount(itemID: "item") == 0)
        let committedPolicy = try await f.repository.itemPolicy(itemID: "item", vaultID: "vault")?.vaultSelection
        await #expect(throws: OfflineModeService.Error.persistenceFailed) {
            try await service.retrySelectedCopies(vaultID: "vault")
        }
        await repository.failCandidateQueries(false)
        try await service.retrySelectedCopies(vaultID: "vault")
        await service.waitUntilIdle()
        #expect(try await f.repository.itemPolicy(itemID: "item", vaultID: "vault")?.vaultSelection == committedPolicy)
        #expect(try await f.repository.offlineItemSelection(itemId: "item")?.cacheStatus == .cached)
        #expect(await viewer.callCount(itemID: "item") == 1)
        await service.stop()
    }

    @Test func incompleteMetadataSyncDoesNotExpandSelectedVault() async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["item"])
        let viewer = OfflineFixtureViewer()
        let service = f.service(viewer: viewer)
        try await initializeOfflineFixtureService(service)
        try await service.selectWholeVault(true, vaultID: "vault")
        await service.waitUntilIdle()
        try f.database.upsertItems([offlineTestMetadata(id: "new", vaultID: "vault")])
        await service.metadataDidSynchronize(allowMembershipExpansion: false, eligibleItemIDs: Set(f.items.map(\.id)).union(["new"]))
        await service.waitUntilIdle()
        #expect(try await f.repository.offlineItemSelection(itemId: "new") == nil)
        #expect(await viewer.callCount(itemID: "new") == 0)
        #expect(await viewer.callCount(itemID: "item") == 2)
        await service.stop()
    }

    @Test func freshEventBeforeInitializationCannotOpenAdmission() async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["item"])
        let service = f.service()
        await service.updateSelectionObservation(generation: offlineFixtureObservationGeneration, status: .starting)
        await service.updateSelectionObservation(generation: offlineFixtureObservationGeneration, status: .fresh)
        try await service.initialize()
        await #expect(throws: OfflineModeService.Error.selectionSuspended) {
            try await service.makeAvailableOffline(item: f.items[0], shareId: "share")
        }
        await service.updateSelectionObservation(generation: offlineFixtureObservationGeneration, status: .fresh)
        try await service.makeAvailableOffline(item: f.items[0], shareId: "share")
        #expect(try await service.availability(for: f.items[0]) != .notCached)
        await service.stop()
    }

    @Test func deselectReselectInvalidatesObsoleteQueuedPolicyJobs() async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["a", "b", "c", "d", "e"])
        let recorder = OfflineWorkRecorder()
        let viewer = OfflineFixtureViewer(beforeViewItem: { id in try await recorder.run(serviceTestCandidate(id)) })
        let service = f.service(viewer: viewer)
        try await initializeOfflineFixtureService(service)
        try await service.selectWholeVault(true, vaultID: "vault")
        try await recorder.waitForStartedCount(4)
        let oldPolicy = try await f.repository.itemPolicy(itemID: "e", vaultID: "vault")?.vaultSelection
        try await service.selectWholeVault(false, vaultID: "vault")
        #expect(try await f.repository.offlineItemSelections().isEmpty)
        try await service.selectWholeVault(true, vaultID: "vault")
        try await recorder.waitForStartedCount(8)
        #expect(try await f.repository.itemPolicy(itemID: "e", vaultID: "vault")?.vaultSelection != oldPolicy)
        await recorder.releaseAll()
        await service.waitUntilIdle()
        #expect(await viewer.callCount(itemID: "e") == 1)
        #expect(try await f.repository.offlineItemSelections().count == 5)
        #expect(try await f.repository.offlineItemSelections().allSatisfy { !$0.isManuallySelected && $0.cacheStatus == .cached })
        await service.stop()
    }

    @Test func lateManualWaiterCancellationDoesNotReverseCommittedSnapshot() async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["item"])
        let gate = OfflineTestGate()
        let repository = OfflineSnapshotRepository(database: f.database, afterPublication: { try? await gate.wait() })
        let service = OfflineModeService(repository: repository, codec: f.codec(), cliService: OfflineFixtureViewer())
        try await initializeOfflineFixtureService(service)
        let manual = Task { try await service.makeAvailableOffline(item: f.items[0], shareId: "share") }
        try await gate.waitUntilEntered()
        manual.cancel()
        _ = await manual.result
        #expect(try await f.repository.offlineItemSelection(itemId: "item")?.cacheStatus == .cached)
        #expect(try await f.repository.hasPersistedSnapshots())
        await gate.open()
        await service.waitUntilIdle()
        #expect(try await f.repository.offlineItemSelection(itemId: "item")?.cacheStatus == .cached)
        await service.stop()
    }

    @Test func failedSurvivorCaptureLeavesPolicyAndManualWorkUntouched() async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["item"])
        let repository = RecoveryControlledRepository(base: f.repository)
        let gate = OfflineTestGate()
        let viewer = OfflineFixtureViewer(beforeView: { try await gate.wait() })
        let service = OfflineModeService(repository: repository, codec: f.codec(), cliService: viewer)
        try await initializeOfflineFixtureService(service)
        try await service.selectWholeVault(true, vaultID: "vault")
        try await gate.waitUntilEntered()
        try await service.keepOfflineIndividually(f.items[0])
        await repository.failCatalogReads()
        await #expect(throws: OfflineModeService.Error.persistenceFailed) {
            try await service.selectWholeVault(false, vaultID: "vault")
        }
        #expect(try await f.repository.offlineVaultIds() == ["vault"])
        await gate.open()
        await service.waitUntilIdle()
        #expect(try await f.repository.offlineItemSelection(itemId: "item")?.cacheStatus == .cached)
        await service.stop()
    }

    @Test func failedRevocationRetainsCommittedSelection() async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["item"])
        let service = f.service()
        try await initializeOfflineFixtureService(service)
        try await service.makeAvailableOffline(item: f.items[0], shareId: "share")
        let before = try await OfflinePersistedTestState.capture(database: f.database, itemID: "item")
        try await f.database.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER rejectRemoval BEFORE DELETE ON offlineItems BEGIN SELECT RAISE(ABORT, 'fixture'); END")
        }
        await #expect(throws: OfflineModeService.Error.persistenceFailed) { try await service.removeOfflineItem(itemId: "item") }
        #expect(try await OfflinePersistedTestState.capture(database: f.database, itemID: "item") == before)
        await service.stop()
    }

    @Test func selectionRequiresSuccessfulInitialization() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let service = fixture.service()
        let item = try #require(fixture.items.first)

        await #expect(throws: OfflineModeService.Error.notInitialized) {
            try await service.makeAvailableOffline(item: item, shareId: "share")
        }
        try await initializeOfflineFixtureService(service)
        try await service.makeAvailableOffline(item: item, shareId: "share")

        #expect(try await fixture.repository.hasPersistedSnapshots())
        #expect(try await fixture.repository.offlineItemSelection(itemId: item.id)?.cacheStatus == .cached)
    }

    @Test func invalidLiveIdentityReleasesOnlyItsProvisionalRequest() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let viewer = InvalidFixtureViewer()
        let service = OfflineModeService(repository: fixture.repository, codec: fixture.codec(), cliService: viewer)
        let item = try #require(fixture.items.first)
        try await initializeOfflineFixtureService(service)

        await #expect(throws: OfflineModeService.Error.snapshotUnavailable) {
            try await service.makeAvailableOffline(item: item, shareId: "share")
        }

        #expect(try await fixture.repository.hasPersistedSnapshots() == false)
        let selection = try #require(try await fixture.repository.offlineItemSelection(itemId: item.id))
        #expect(selection.isManuallySelected)
        #expect(selection.cacheStatus == .unavailable)
        let pending = try await fixture.database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT pendingRequestId FROM offlineItems WHERE itemId = ?", arguments: [item.id])
        }
        #expect(pending == nil)
    }

    @Test func pendingFetchCannotSurviveGlobalPurge() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let gate = OfflineTestGate()
        let viewer = OfflineFixtureViewer(beforeView: { try await gate.wait() })
        let codec = OfflineSnapshotCodec(
            keyMaterialProvider: OfflineFixtureKeys(),
            hasPersistedSnapshots: { try await fixture.repository.hasPersistedSnapshots() }
        )
        let service = OfflineModeService(repository: fixture.repository, codec: codec, cliService: viewer)
        try await initializeOfflineFixtureService(service)
        let item = try #require(fixture.items.first)
        let task = Task { try await service.makeAvailableOffline(item: item, shareId: "share") }
        do {
            try await gate.waitUntilEntered()
            try await service.removeAllOfflineData()
            await gate.open()
            _ = await task.result
        } catch {
            task.cancel()
            await gate.open()
            _ = await task.result
            throw error
        }
        #expect(try await fixture.repository.hasPersistedSnapshots() == false)
        #expect(try await fixture.repository.offlineItemSelections().isEmpty)
    }

    @Test func refreshFailureRetainsThePreviouslyCommittedSnapshot() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let item = try #require(fixture.items.first)
        let service = fixture.service()
        try await initializeOfflineFixtureService(service)
        try await service.makeAvailableOffline(item: item, shareId: "share")
        let failing = OfflineFixtureViewer(beforeView: { throw CLIError.notLoggedIn })
        let refreshService = OfflineModeService(repository: fixture.repository, codec: fixture.codec(), cliService: failing)
        try await refreshService.initialize()

        await refreshService.refreshSelectedSnapshots(
            vaults: [PassVault(id: "vault", name: "Vault", shareId: "share")], items: [item]
        )

        await refreshService.waitUntilIdle()
        #expect(try await fixture.repository.hasPersistedSnapshots())
        #expect(try await fixture.repository.offlineItemSelection(itemId: item.id)?.cacheStatus == .failed)
    }

    @Test func failedInitializationAllowsRemovalAndCoalescesExplicitRetry() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let item = try #require(fixture.items.first)
        let seededService = fixture.service()
        try await initializeOfflineFixtureService(seededService)
        try await seededService.makeAvailableOffline(item: item, shareId: "share")

        let gate = OfflineTestGate()
        let recovery = RecoveryControl(gate: gate)
        let joinRecorder = InitializationJoinRecorder()
        let repository = RecoveryControlledRepository(base: fixture.repository, recovery: recovery)
        let service = OfflineModeService(
            repository: repository, codec: fixture.codec(), cliService: OfflineFixtureViewer(),
            initializationJoinMarker: { joinRecorder.mark() }
        )

        await #expect(throws: OfflinePersistenceError.persistenceFailed) {
            try await service.initialize()
        }
        #expect(await service.requiresInitializationRetry())
        await #expect(throws: OfflineModeService.Error.notInitialized) {
            try await service.makeAvailableOffline(item: item, shareId: "share")
        }

        try await service.removeOfflineItem(itemId: item.id)
        try await service.removeAllOfflineData()
        #expect(try await fixture.repository.offlineItemSelections().isEmpty)
        #expect(try await fixture.repository.offlineVaultIds().isEmpty)

        await recovery.blockRetries()
        let firstRetry = Task { try await service.initialize() }
        var secondRetry: Task<Void, Swift.Error>?
        do {
            try await gate.waitUntilEntered()
            secondRetry = Task {
                try await service.initialize()
                #expect(await service.isReady())
                await service.updateSelectionObservation(generation: offlineFixtureObservationGeneration, status: .starting)
                await service.updateSelectionObservation(generation: offlineFixtureObservationGeneration, status: .fresh)
                try await service.makeAvailableOffline(item: item, shareId: "share")
            }
            await joinRecorder.waitUntilMarked()
            await gate.open()
            try await firstRetry.value
            try await secondRetry?.value
        } catch {
            firstRetry.cancel()
            secondRetry?.cancel()
            await gate.open()
            _ = await firstRetry.result
            if let secondRetry { _ = await secondRetry.result }
            throw error
        }

        #expect(await recovery.callCount() == 2)
        #expect(await service.isReady())
        #expect(await service.requiresInitializationRetry() == false)
        #expect(try await fixture.repository.hasPersistedSnapshots())
    }
}

private extension OfflineModeService {
    /// The release task inherits the service executor. It can run only after the
    /// real revocation suspends to drain metadata permits, not on a timed poll.
    func deselectPausedFixtureIntent(gate: OfflineTestGate) async throws {
        let release = Task {
            #expect(!revocations.isEmpty && !permitDrainWaiters.isEmpty)
            await gate.open()
        }
        try await selectWholeVault(false, vaultID: "vault")
        await release.value
    }

    func revokePausedFixtureIntent(itemID: String, purge: Bool, gate: OfflineTestGate) async throws {
        let release = Task {
            #expect(!revocations.isEmpty)
            #expect(!permitDrainWaiters.isEmpty)
            await gate.open()
        }
        if purge { try await removeAllOfflineData() }
        else { try await removeOfflineItem(itemId: itemID) }
        await release.value
    }
}

private func serviceTestCandidate(_ id: String) -> OfflineSnapshotWorkCandidate {
    OfflineSnapshotWorkCandidate(key: OfflineSnapshotKey(vaultId: "vault", itemId: id, schemaVersion: OfflineSnapshotLimits.schemaVersion),
                                 shareID: "share", metadataModifyTime: Date(timeIntervalSince1970: 2),
                                 itemType: .login, intent: .vaultMaterialize(policyGeneration: UUID()))
}

private actor OfflineViewerFailureControl {
    private var failing = true
    func succeed() { failing = false }
    func check() throws { if failing { throw CLIError.notLoggedIn } }
}

private struct InvalidFixtureViewer: OfflineItemViewing {
    func viewItem(itemId: String, shareId: String) async throws -> CLIItem {
        try offlineTestCLIItem(id: "other", vaultID: "vault", shareID: shareId, password: "fake-password")
    }
}

private struct InitializationJoinRecorder: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    }

    func mark() { continuation.yield() }

    func waitUntilMarked() async {
        for await _ in stream { return }
    }
}

private actor RecoveryControl {
    private let gate: OfflineTestGate
    private var shouldFail = true
    private var retriesBlocked = false
    private var calls = 0

    init(gate: OfflineTestGate) { self.gate = gate }

    func recover() async throws {
        calls += 1
        if shouldFail {
            shouldFail = false
            throw OfflinePersistenceError.persistenceFailed
        }
        if retriesBlocked { try await gate.wait() }
    }

    func blockRetries() { retriesBlocked = true }
    func callCount() -> Int { calls }
}

private actor RecoveryControlledRepository: OfflineSnapshotPersisting {
    private let base: OfflineSnapshotRepository
    private let recovery: RecoveryControl?
    private let candidatesGate: OfflineTestGate?
    private let mutationGate: OfflineTestGate?
    private let reservationGate: OfflineTestGate?
    private let deselectionGate: OfflineTestGate?
    private var events: [String] = []
    private var catalogReadsFail = false
    private var candidateQueriesFail = false
    func failCandidateQueries(_ fail: Bool) { candidateQueriesFail = fail }
    func failCatalogReads() { catalogReadsFail = true }
    func eventTrace() -> [String] { events }

    init(base: OfflineSnapshotRepository, recovery: RecoveryControl? = nil,
         candidatesGate: OfflineTestGate? = nil, mutationGate: OfflineTestGate? = nil,
         reservationGate: OfflineTestGate? = nil, deselectionGate: OfflineTestGate? = nil) {
        self.base = base
        self.recovery = recovery
        self.candidatesGate = candidatesGate
        self.mutationGate = mutationGate
        self.reservationGate = reservationGate
        self.deselectionGate = deselectionGate
    }

    func beginRequest(
        itemID: String, vaultID: String, shareID: String, kind: OfflineRequestKind,
        expectedSelectionGeneration: UUID?, expectedMetadataModifyTime: Date?, expectedItemType: ItemType?
    ) async throws -> OfflineRequestToken? {
        try await reservationGate?.wait()
        return try await base.beginRequest(itemID: itemID, vaultID: vaultID, shareID: shareID, kind: kind,
                                    expectedSelectionGeneration: expectedSelectionGeneration,
                                    expectedMetadataModifyTime: expectedMetadataModifyTime,
                                    expectedItemType: expectedItemType)
    }

    func publish(
        _ snapshot: EncryptedOfflineSnapshot, for request: OfflineRequestToken, refreshedAt: Date
    ) async throws -> Bool {
        try await base.publish(snapshot, for: request, refreshedAt: refreshedAt)
    }
    func finishRequest(_ request: OfflineRequestToken, failed: Bool) async throws { try await base.finishRequest(request, failed: failed) }
    func setVaultSelected(_ selected: Bool, vaultID: String) async throws -> OfflineVaultSelection? {
        if !selected { try await deselectionGate?.wait() }
        return try await base.setVaultSelected(selected, vaultID: vaultID)
    }
    func selectItemManually(itemID: String, vaultID: String, shareID: String) async throws -> UUID {
        events.append("manual-entered")
        try await mutationGate?.wait()
        let generation = try await base.selectItemManually(itemID: itemID, vaultID: vaultID, shareID: shareID)
        events.append("manual-committed")
        return generation
    }
    func keepItemOfflineIndividually(itemID: String, vaultID: String) async throws { try await base.keepItemOfflineIndividually(itemID: itemID, vaultID: vaultID) }
    func itemPolicy(itemID: String, vaultID: String) async throws -> OfflineItemPolicy? { try await base.itemPolicy(itemID: itemID, vaultID: vaultID) }
    func workCandidates(
        vaultID: String?, includeNewSelections: Bool, refreshExisting: Bool
    ) async throws -> [OfflineSnapshotWorkCandidate] {
        events.append("candidates-query")
        if candidateQueriesFail { throw OfflinePersistenceError.persistenceFailed }
        try await candidatesGate?.wait()
        return try await base.workCandidates(
            vaultID: vaultID,
            includeNewSelections: includeNewSelections,
            refreshExisting: refreshExisting
        )
    }
    func removeItem(_ itemID: String) async throws { try await base.removeItem(itemID) }
    func purge() async throws { try await base.purge() }
    func recoverAbandonedRequests() async throws { try await recovery?.recover(); try await base.recoverAbandonedRequests() }
    func authorizedSnapshot(for key: OfflineSnapshotKey) async throws -> EncryptedOfflineSnapshot? { try await base.authorizedSnapshot(for: key) }
    func hasAuthorizedSnapshot(for key: OfflineSnapshotKey) async throws -> Bool { try await base.hasAuthorizedSnapshot(for: key) }
    func isAuthorized(_ snapshot: EncryptedOfflineSnapshot) async throws -> Bool { try await base.isAuthorized(snapshot) }
    func discardCorruptSnapshot(_ snapshot: EncryptedOfflineSnapshot) async throws { try await base.discardCorruptSnapshot(snapshot) }
    func hasPersistedSnapshots() async throws -> Bool { try await base.hasPersistedSnapshots() }
    func offlineVaultIds() async throws -> Set<String> { try await base.offlineVaultIds() }
    func offlineItemSelection(itemId: String) async throws -> OfflineItemSelection? { try await base.offlineItemSelection(itemId: itemId) }
    func offlineItemSelections() async throws -> [OfflineItemSelection] {
        if catalogReadsFail { throw OfflinePersistenceError.persistenceFailed }
        return try await base.offlineItemSelections()
    }
}
