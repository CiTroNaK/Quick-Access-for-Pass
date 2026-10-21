import Foundation
import GRDB
import Synchronization
import Testing
@testable import Quick_Access_for_Pass

@Suite("OfflineModeCoordinator")
@MainActor
struct OfflineModeCoordinatorTests {
    @Test(.timeLimit(.minutes(1)))
    func retryForwardsCapturedIdentityThroughCoordinator() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["target", "neighbor"])
        let viewer = OfflineFixtureViewer()
        let service = fixture.service(viewer: viewer)
        try await initializeOfflineFixtureService(service)
        _ = try await fixture.repository.selectItemManually(itemID: "target", vaultID: "vault", shareID: "share")
        _ = try await fixture.repository.selectItemManually(itemID: "neighbor", vaultID: "vault", shareID: "share")
        let initial = try await fixture.database.reader.read { try OfflineCatalogObservation.presentation(in: $0) }
        let coordinator = OfflineModeCoordinator(
            service: service, observation: SequencedObservation(streams: [completedStream(initial), failedStream()]),
            shareIDForVault: { _ in "share" }
        )
        await #expect(throws: OfflineModeCoordinator.Error.observationUnavailable) {
            try await coordinator.retryOfflineItem(itemID: "target", vaultID: "vault")
        }
        await coordinator.startObservation().value
        #expect(coordinator.canMakeNewSelections)

        #expect(try await coordinator.retryOfflineItem(itemID: "target", vaultID: "vault") == .submitted)
        await service.waitUntilIdle()
        #expect(await viewer.callCount(itemID: "target") == 1)
        #expect(await viewer.callCount(itemID: "neighbor") == 0)
        #expect(try await coordinator.retryOfflineItem(itemID: "neighbor", vaultID: "wrong-vault") == .unavailable)
        #expect(try await fixture.repository.offlineItemSelection(itemId: "neighbor")?.isManuallySelected == true)
        await coordinator.retryObservation().value
        await #expect(throws: OfflineModeCoordinator.Error.observationUnavailable) {
            try await coordinator.retryOfflineItem(itemID: "target", vaultID: "vault")
        }
        coordinator.stopObservation()
        await service.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func settingsPurgeRemainsAvailableAfterInitialObservationFailureWithoutRetry() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let item = try #require(fixture.items.first)
        let keys = OfflineFixtureKeys()
        let codec = fixture.codec(keys: keys)
        let service = OfflineModeService(repository: fixture.repository, codec: codec, cliService: OfflineFixtureViewer())
        try await initializeOfflineFixtureService(service)
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        try await service.makeAvailableOffline(item: item, shareId: "share")
        let retained = try await fixture.database.reader.read { db in
            try OfflineCatalogObservation.presentation(in: db)
        }
        let keyBefore = await keys.existingSnapshotKey()
        let coordinator = OfflineModeCoordinator(
            service: service, observation: SequencedObservation(streams: [failedStream()]), shareIDForVault: { _ in "share" }
        )
        coordinator.apply(retained)
        await coordinator.startObservation().value
        #expect(coordinator.observationErrorMessage == "Offline status could not be updated. Retry offline setup.")
        #expect(coordinator.vaults == retained.vaults && coordinator.itemGroups == retained.itemGroups)
        #expect(coordinator.canMakeNewSelections == false)
        #expect(try await fixture.repository.hasPersistedSnapshots())
        await #expect(throws: OfflineModeService.Error.selectionSuspended) {
            try await service.makeAvailableOffline(item: item, shareId: "share")
        }
        await #expect(throws: OfflineModeCoordinator.Error.observationUnavailable) {
            try await coordinator.keepOfflineIndividually(item)
        }
        try await coordinator.removeOfflineItem(itemId: item.id)
        #expect(try await fixture.repository.offlineItemSelections().isEmpty)
        #expect(try await fixture.repository.hasPersistedSnapshots() == false)
        // Revocation and purge stay callable after observation failure.
        #expect(OfflineSettingsTab.isPurgeDisabled(coordinator) == false)
        try await coordinator.removeAllOfflineData()
        #expect(try await fixture.repository.hasPersistedSnapshots() == false)
        #expect(try await fixture.repository.offlineVaultIds().isEmpty)
        #expect(try await fixture.repository.offlineItemSelections().isEmpty)
        #expect(await keys.existingSnapshotKey() == keyBefore)
        #expect(await keys.createCount() == 0)
        #expect(coordinator.observationErrorMessage != nil)
        #expect(coordinator.isPerformingTask == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func backgroundRemovalUpdatesDetailWithoutExplicitReload() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        let observation = OfflineCatalogObservation(database: fixture.database)
        var iterator = observation.snapshots().makeAsyncIterator()
        _ = try await iterator.next()
        _ = try await fixture.repository.setVaultSelected(false, vaultID: "vault")
        let next = try #require(try await iterator.next())
        #expect(next.selectedVaultIDs.isEmpty)
        #expect(next.availabilityByItemID.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func nativeObservationTracksSelectedItemDeletionWithoutReload() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let item = try #require(fixture.items.first)
        let service = fixture.service()
        try await initializeOfflineFixtureService(service)
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        try await service.makeAvailableOffline(item: item, shareId: "share")
        let observation = OfflineCatalogObservation(database: fixture.database)
        var iterator = observation.snapshots().makeAsyncIterator()
        let initial = try #require(try await iterator.next())
        #expect(initial.availabilityByItemID[item.id] == .available(lastRefreshedAt: initial.vaults.first?.lastRefreshedAt))

        try await fixture.repository.removeItem(item.id)
        let removed = try #require(try await iterator.next())
        #expect(removed.availabilityByItemID[item.id] == nil)
        #expect(removed.itemGroups.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func provisionalSelectionIsExcludedAndFailedRefreshRetainsLastSuccessTimestamp() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let item = try #require(fixture.items.first)
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        let observation = OfflineCatalogObservation(database: fixture.database)
        var iterator = observation.snapshots().makeAsyncIterator()
        _ = try await iterator.next()

        _ = try #require(try await fixture.repository.beginRequest(
            itemID: item.id, vaultID: item.vaultId, shareID: "share", kind: .selection
        ))
        let provisional = try #require(try await iterator.next())
        #expect(provisional.vaults.first?.selectedCount == 0)
        #expect(provisional.itemGroups.isEmpty)

        try await fixture.repository.recoverAbandonedRequests()
        let service = fixture.service()
        try await initializeOfflineFixtureService(service)
        try await service.makeAvailableOffline(item: item, shareId: "share")
        var resolvedTimestamp: Date?
        while let emission = try await iterator.next() {
            if case .available(let lastRefreshedAt) = emission.availabilityByItemID[item.id] {
                resolvedTimestamp = lastRefreshedAt
                break
            }
        }
        let timestamp = try #require(resolvedTimestamp)
        try OfflineCatalogFixtureSupport.updateCacheStatus(in: fixture.database, itemId: item.id, status: .failed, refreshedAt: timestamp)
        let stale = try #require(try await iterator.next())
        #expect(stale.availabilityByItemID[item.id] == .stale(lastRefreshedAt: timestamp))
        #expect(stale.vaults.first?.lastRefreshedAt == timestamp)
    }

    @Test(.timeLimit(.minutes(1)))
    func structurallyValidSnapshotIsNotUsableWhenSelectionIsUnavailable() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let item = try #require(fixture.items.first)
        let service = fixture.service()
        try await initializeOfflineFixtureService(service)
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        try await service.makeAvailableOffline(item: item, shareId: "share")
        try OfflineCatalogFixtureSupport.updateCacheStatus(in: fixture.database, itemId: item.id, status: .unavailable, refreshedAt: .distantPast)

        let observation = OfflineCatalogObservation(database: fixture.database)
        var iterator = observation.snapshots().makeAsyncIterator()
        let presentation = try #require(try await iterator.next())
        let vault = try #require(presentation.vaults.first)
        let row = try #require(presentation.itemGroups.first?.items.first)
        #expect(vault.selectedCount == 1)
        #expect(vault.usableCount == 0)
        #expect(row.hasUsableSnapshot == false)
        #expect(presentation.availabilityByItemID[item.id] == .unavailable)
    }

    @Test(.timeLimit(.minutes(1)))
    func terminalObservationFailureRetainsDisplayAndRetryRestoresSelectionControls() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let item = try #require(fixture.items.first)
        let service = fixture.service()
        let retained = presentation(selectedVaultIDs: ["vault"], availability: .notCached)
        let restored = presentation(selectedVaultIDs: ["vault"], availability: .available(lastRefreshedAt: .distantPast))
        let observation = SequencedObservation(streams: [
            failedStream(),
            completedStream(restored)
        ])
        let coordinator = OfflineModeCoordinator(service: service, observation: observation, shareIDForVault: { _ in "share" })
        coordinator.apply(retained)

        await coordinator.startObservation().value
        #expect(coordinator.vaults == retained.vaults)
        #expect(coordinator.observationErrorMessage != nil)
        #expect(coordinator.canMakeNewSelections == false)
        await #expect(throws: OfflineModeCoordinator.Error.observationUnavailable) {
            try await coordinator.makeAvailableOffline(item)
        }
        await #expect(throws: OfflineModeCoordinator.Error.observationUnavailable) {
            try await coordinator.selectWholeVault(true, vaultID: "vault")
        }
        try await coordinator.removeOfflineItem(itemId: item.id)
        try await coordinator.removeAllOfflineData()

        await coordinator.retryObservation().value
        #expect(coordinator.observationErrorMessage == nil)
        #expect(coordinator.canMakeNewSelections)
        #expect(coordinator.availability(for: item) == .available(lastRefreshedAt: .distantPast))
    }

    @Test(.timeLimit(.minutes(1)))
    func promotionGuardSerializesConflictingMutationsButIgnoresUnrelatedPreparation() async throws {
        let gates = PromotionMutationGates()
        let service = GatedPromotionService(gates: gates)
        let generation = UUID()
        let key = OfflineSnapshotKey(vaultId: "vault", itemId: "selected", schemaVersion: OfflineSnapshotLimits.schemaVersion)
        let selectedItem = OfflineItemSettingsRow(
            itemId: "selected", vaultId: "vault", title: "Selected", itemType: .login,
            status: .cached, lastRefreshedAt: nil, hasUsableSnapshot: true,
            item: offlineTestMetadata(id: "selected", vaultID: "vault")
        )
        let presentation = OfflinePresentationSnapshot(
            vaults: [OfflineVaultSettingsRow(
                id: "vault", vaultName: "Vault", isSelected: true,
                selectedCount: 1, usableCount: 1, lastRefreshedAt: nil
            )],
            itemGroups: [OfflineItemSettingsGroup(vaultId: "vault", vaultName: "Vault", items: [selectedItem])],
            selectedVaultIDs: ["vault"],
            policyByItemID: ["selected": OfflineItemPolicy(
                key: key, isManuallySelected: false,
                vaultSelection: OfflineVaultSelection(vaultID: "vault", generation: generation), isExcluded: false
            )],
            availabilityByItemID: ["selected": .available(lastRefreshedAt: nil)]
        )
        let coordinator = OfflineModeCoordinator(
            service: service,
            observation: SequencedObservation(streams: [completedStream(presentation)]),
            shareIDForVault: { _ in "share" }
        )
        await coordinator.startObservation().value
        let target = offlineTestMetadata(id: "selected", vaultID: "vault")
        let unrelated = offlineTestMetadata(id: "background", vaultID: "another-vault")

        let backgroundPreparation = Task { try await coordinator.makeAvailableOffline(unrelated) }
        try await gates.backgroundPreparation.waitUntilEntered()
        #expect(coordinator.canKeepOfflineIndividually(target.id))
        await gates.backgroundPreparation.open()
        try await backgroundPreparation.value

        let promotion = Task { try await coordinator.keepOfflineIndividually(target) }
        try await gates.promotion.waitUntilEntered()
        #expect(coordinator.canKeepOfflineIndividually(target.id) == false, "The in-flight promotion owns this item's mutation ID.")
        #expect(coordinator.canRemoveItem(target.id) == false)
        #expect(coordinator.canDeselectVault("vault") == false)
        #expect(coordinator.canPurge == false)
        var duplicatePromotionThrew = false
        do {
            try await coordinator.keepOfflineIndividually(target)
        } catch {
            duplicatePromotionThrew = true
        }
        #expect(duplicatePromotionThrew)
        #expect(await service.promotionCount() == 1)
        #expect(coordinator.canPurge == false)
        await gates.promotion.open()
        try await promotion.value
        #expect(coordinator.canPurge)

        let vaultMutation = Task { try await coordinator.selectWholeVault(false, vaultID: "vault") }
        try await gates.vaultMutation.waitUntilEntered()
        #expect(coordinator.canKeepOfflineIndividually(target.id) == false, "A mutation of the selected vault blocks promotion.")
        await gates.vaultMutation.open()
        try await vaultMutation.value

        let purge = Task { try await coordinator.removeAllOfflineData() }
        try await gates.purge.waitUntilEntered()
        #expect(coordinator.canKeepOfflineIndividually(target.id) == false, "Global purge ownership blocks promotion.")
        await gates.purge.open()
        try await purge.value
    }

    @Test(.timeLimit(.minutes(1)))
    func settingsRevocationGuardsRemainOpenDuringPausedVaultPreparation() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let item = try #require(fixture.items.first)
        let gate = OfflineTestGate()
        let viewer = OfflineFixtureViewer(beforeViewItem: { _ in try await gate.wait() })
        let service = fixture.service(viewer: viewer)
        try await initializeOfflineFixtureService(service)
        let initial = try await fixture.database.reader.read { try OfflineCatalogObservation.presentation(in: $0) }
        let coordinator = OfflineModeCoordinator(
            service: service,
            observation: SequencedObservation(streams: [completedStream(initial)]),
            shareIDForVault: { _ in "share" }
        )
        await coordinator.startObservation().value

        let selection = Task { try await coordinator.selectWholeVault(true, vaultID: "vault") }
        try await gate.waitUntilEntered()
        let selected = try await fixture.database.reader.read { try OfflineCatalogObservation.presentation(in: $0) }
        coordinator.apply(selected)
        #expect(coordinator.canDeselectVault("vault"))
        #expect(coordinator.canRemoveItem(item.id))
        #expect(coordinator.canPurge)

        await gate.open()
        try await selection.value
        await service.waitUntilIdle()
        await service.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledOldObservationCannotClearNewerFailureBeforeCurrentEmission() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let old = ControlledObservationStream()
        let current = ControlledObservationStream()
        let restored = presentation(
            selectedVaultIDs: ["vault"], availability: .available(lastRefreshedAt: .distantPast)
        )
        let observation = ControlledObservation(streams: [failedStream(), old.stream, current.stream])
        let coordinator = OfflineModeCoordinator(
            service: fixture.service(), observation: observation, shareIDForVault: { _ in "share" }
        )

        await coordinator.startObservation().value
        #expect(coordinator.observationErrorMessage != nil)

        let oldTask = coordinator.startObservation()
        await observation.waitForSubscription(2)
        let currentTask = coordinator.startObservation()
        await observation.waitForSubscription(3)

        switch old.continuation.yield(presentation(selectedVaultIDs: ["old-vault"], availability: .notCached)) {
        case .terminated:
            break
        case .enqueued, .dropped:
            Issue.record("The cancelled native old observation stream was not terminated.")
        @unknown default:
            Issue.record("The cancelled native old observation stream returned an unknown yield result.")
        }
        old.continuation.finish(throwing: TestObservationError.terminal)
        #expect(coordinator.observationErrorMessage != nil)
        #expect(coordinator.vaults.isEmpty)

        current.continuation.yield(restored)
        current.continuation.finish()
        await currentTask.value
        await oldTask.value
        #expect(coordinator.observationErrorMessage == nil)
        #expect(coordinator.vaults == restored.vaults)
        let item = try #require(fixture.items.first)
        #expect(coordinator.availability(for: item) == .available(lastRefreshedAt: .distantPast))
    }

    @Test(.timeLimit(.minutes(1)))
    func startupRecoveryFailureWaitsForExplicitRetry() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let repository = CountingRecoveryRepository(base: fixture.repository)
        let service = OfflineModeService(repository: repository, codec: fixture.codec(), cliService: OfflineFixtureViewer())
        let ready = presentation(selectedVaultIDs: [], availability: .notCached)
        let observation = SequencedObservation(streams: [failedStream(), completedStream(ready), completedStream(ready)])
        let coordinator = OfflineModeCoordinator(service: service, observation: observation, shareIDForVault: { _ in "share" })

        await coordinator.startObservation().value
        #expect(await repository.recoveryCount() == 1)
        #expect(coordinator.requiresInitializationRetry)
        await coordinator.startObservation().value
        #expect(await repository.recoveryCount() == 1)
        #expect(coordinator.canMakeNewSelections == false)

        let retryTask = try await coordinator.retryInitialization()
        #expect(coordinator.canMakeNewSelections == false)
        await retryTask.value
        #expect(coordinator.canMakeNewSelections)
        #expect(await repository.recoveryCount() == 2)
        let item = try #require(fixture.items.first)
        try await coordinator.makeAvailableOffline(item)
        #expect(try await fixture.repository.itemPolicy(itemID: item.id, vaultID: item.vaultId)?.isManuallySelected == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func lateReadinessFailureCannotClobberNewObservationGeneration() async throws {
        let gate = NonCancellableTestGate()
        let service = LateReadinessService(gate: gate)
        let restored = presentation(selectedVaultIDs: ["vault"], availability: .notCached)
        let observation = SequencedObservation(streams: [completedStream(restored)])
        let coordinator = OfflineModeCoordinator(service: service, observation: observation, shareIDForVault: { _ in "share" })

        let oldTask = coordinator.startObservation()
        await gate.waitUntilEntered()
        let currentTask = coordinator.startObservation()
        await currentTask.value
        #expect(coordinator.requiresInitializationRetry == false)
        await gate.open()
        await oldTask.value
        #expect(coordinator.requiresInitializationRetry == false)
        #expect(coordinator.observationErrorMessage == nil)
    }

    @Test func availabilityIsPureAndRejectsCrossVaultMetadata() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let service = fixture.service()
        let coordinator = OfflineModeCoordinator(
            service: service,
            observation: StaticOfflineObservation(),
            shareIDForVault: { _ in "share" }
        )
        var selectionInputChanges = 0
        coordinator.onDetailSelectionInputsChanged = { selectionInputChanges += 1 }
        let row = OfflineItemSettingsRow(
            itemId: "item", vaultId: "vault", title: "Offline example", itemType: .login,
            status: .cached, lastRefreshedAt: .distantPast, hasUsableSnapshot: true,
            item: offlineTestMetadata(id: "item", vaultID: "vault")
        )
        coordinator.apply(OfflinePresentationSnapshot(
            vaults: [OfflineVaultSettingsRow(
                id: "vault", vaultName: "Vault", isSelected: true,
                selectedCount: 1, usableCount: 1, lastRefreshedAt: .distantPast
            )],
            itemGroups: [OfflineItemSettingsGroup(vaultId: "vault", vaultName: "Vault", items: [row])],
            selectedVaultIDs: ["vault", "other-vault"],
            policyByItemID: [:],
            availabilityByItemID: ["item": .available(lastRefreshedAt: .distantPast)]
        ))

        #expect(selectionInputChanges == 1)
        let item = try #require(fixture.items.first)
        #expect(coordinator.availability(for: item) == .available(lastRefreshedAt: .distantPast))
        let mismatched = PassItem(
            id: item.id, vaultId: "other-vault", title: item.title, itemType: item.itemType,
            subtitle: item.subtitle, url: item.url, hasTOTP: item.hasTOTP, state: item.state,
            createTime: item.createTime, modifyTime: item.modifyTime, useCount: item.useCount, lastUsedAt: item.lastUsedAt
        )
        #expect(coordinator.availability(for: mismatched) == .notCached)
        #expect(coordinator.isOperating(on: item) == false)
    }
}

private struct StaticOfflineObservation: OfflineCatalogObserving {
    func snapshots() -> AsyncThrowingStream<OfflinePresentationSnapshot, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("OfflineModeCoordinator admission")
@MainActor
struct OfflineModeCoordinatorAdmissionTests {
    @Test(.timeLimit(.minutes(1)))
    func queuedViewModelKeepIsRejectedAfterObservationAdmissionCloses() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let item = offlineTestMetadata(id: "selected", vaultID: "vault")
        let policyKey = OfflineSnapshotKey(
            vaultId: "vault", itemId: item.id, schemaVersion: OfflineSnapshotLimits.schemaVersion
        )
        let selectedRow = OfflineItemSettingsRow(
            itemId: item.id, vaultId: item.vaultId, title: item.title, itemType: item.itemType,
            status: .cached, lastRefreshedAt: .distantPast, hasUsableSnapshot: true, item: item
        )
        let selected = OfflinePresentationSnapshot(
            vaults: [OfflineVaultSettingsRow(
                id: "vault", vaultName: "Vault", isSelected: true,
                selectedCount: 1, usableCount: 1, lastRefreshedAt: .distantPast
            )],
            itemGroups: [OfflineItemSettingsGroup(vaultId: "vault", vaultName: "Vault", items: [selectedRow])],
            selectedVaultIDs: ["vault"],
            policyByItemID: [item.id: OfflineItemPolicy(
                key: policyKey, isManuallySelected: false,
                vaultSelection: OfflineVaultSelection(vaultID: "vault", generation: UUID()), isExcluded: false
            )],
            availabilityByItemID: [item.id: .available(lastRefreshedAt: .distantPast)]
        )
        let service = GatedPromotionService(gates: PromotionMutationGates())
        let coordinator = OfflineModeCoordinator(
            service: service,
            observation: SequencedObservation(streams: [completedStream(selected), failedStream()]),
            shareIDForVault: { _ in "share" }
        )
        await coordinator.startObservation().value
        #expect(coordinator.canKeepOfflineIndividually(item.id))
        let viewModel = QuickAccessViewModel(
            searchService: SearchService(databaseManager: database),
            cliService: PassCLIService(),
            clipboardManager: ClipboardManager(autoClearSeconds: 0),
            onDismiss: {},
            offlineModeCoordinator: coordinator
        )

        viewModel.handleKeepOfflineIndividually(for: item)
        let queuedKeep = try #require(viewModel.inFlightOfflineOperation)
        let failedObservation = coordinator.retryObservation()
        #expect(!coordinator.canMakeNewSelections)
        await queuedKeep.value
        await failedObservation.value

        let promotionCount = await service.promotionCount()
        #expect(promotionCount == 0)
        #expect(viewModel.errorMessage == QuickAccessViewModel.offlineSelectionRetryMessage)
    }
}

private enum TestObservationError: Error { case terminal }

private final class SequencedObservation: OfflineCatalogObserving, Sendable {
    private let streams: Mutex<[AsyncThrowingStream<OfflinePresentationSnapshot, Error>]>

    init(streams: [AsyncThrowingStream<OfflinePresentationSnapshot, Error>]) {
        self.streams = Mutex(streams)
    }

    func snapshots() -> AsyncThrowingStream<OfflinePresentationSnapshot, Error> {
        streams.withLock { streams in
            streams.isEmpty ? AsyncThrowingStream { $0.finish() } : streams.removeFirst()
        }
    }
}

private func failedStream() -> AsyncThrowingStream<OfflinePresentationSnapshot, Error> {
    AsyncThrowingStream { $0.finish(throwing: TestObservationError.terminal) }
}

private func completedStream(_ presentation: OfflinePresentationSnapshot) -> AsyncThrowingStream<OfflinePresentationSnapshot, Error> {
    AsyncThrowingStream { continuation in
        continuation.yield(presentation)
        continuation.finish()
    }
}

@MainActor
private func presentation(
    selectedVaultIDs: Set<String>, availability: OfflineItemAvailability
) -> OfflinePresentationSnapshot {
    let row = OfflineItemSettingsRow(
        itemId: "item", vaultId: "vault", title: "Offline example", itemType: .login,
        status: .cached, lastRefreshedAt: .distantPast, hasUsableSnapshot: true,
        item: offlineTestMetadata(id: "item", vaultID: "vault")
    )
    return OfflinePresentationSnapshot(
        vaults: [OfflineVaultSettingsRow(
            id: "vault", vaultName: "Vault", isSelected: true,
            selectedCount: 1, usableCount: 1, lastRefreshedAt: .distantPast
        )],
        itemGroups: [OfflineItemSettingsGroup(vaultId: "vault", vaultName: "Vault", items: [row])],
        selectedVaultIDs: selectedVaultIDs,
        policyByItemID: [:],
        availabilityByItemID: ["item": availability]
    )
}

private final class ControlledObservation: OfflineCatalogObserving, Sendable {
    private let streams: Mutex<[AsyncThrowingStream<OfflinePresentationSnapshot, Error>]>
    private let subscriptions = SubscriptionRecorder()

    init(streams: [AsyncThrowingStream<OfflinePresentationSnapshot, Error>]) {
        self.streams = Mutex(streams)
    }

    func snapshots() -> AsyncThrowingStream<OfflinePresentationSnapshot, Error> {
        let stream = streams.withLock { streams in
            streams.isEmpty ? AsyncThrowingStream { $0.finish() } : streams.removeFirst()
        }
        Task { await subscriptions.record() }
        return stream
    }

    func waitForSubscription(_ count: Int) async {
        await subscriptions.waitForCount(count)
    }
}

private struct ControlledObservationStream {
    let stream: AsyncThrowingStream<OfflinePresentationSnapshot, Error>
    let continuation: AsyncThrowingStream<OfflinePresentationSnapshot, Error>.Continuation

    init() {
        var capturedContinuation: AsyncThrowingStream<OfflinePresentationSnapshot, Error>.Continuation?
        stream = AsyncThrowingStream { capturedContinuation = $0 }
        continuation = capturedContinuation!
    }
}

private actor SubscriptionRecorder {
    private var count = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record() {
        count += 1
        let readyWaiters = waiters.filter { $0.count <= count }
        waiters.removeAll { $0.count <= count }
        for waiter in readyWaiters {
            waiter.continuation.resume()
        }
    }

    func waitForCount(_ expectedCount: Int) async {
        guard count < expectedCount else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count: expectedCount, continuation: continuation))
        }
    }
}

private actor NonCancellableTestGate {
    private var entered = false
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var entryWaiter: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        guard !isOpen else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}

private struct PromotionMutationGates: Sendable {
    let backgroundPreparation = OfflineTestGate()
    let promotion = OfflineTestGate()
    let vaultMutation = OfflineTestGate()
    let purge = OfflineTestGate()
}

private actor GatedPromotionService: OfflineModeServicing {
    private let gates: PromotionMutationGates
    private var promotions = 0

    init(gates: PromotionMutationGates) { self.gates = gates }
    func initialize() async throws {}
    func requiresInitializationRetry() async -> Bool { false }
    func isReady() async -> Bool { true }
    func makeAvailableOffline(item: PassItem, shareId: String) async throws {
        if item.id == "background" { try await gates.backgroundPreparation.wait() }
    }
    func removeOfflineItem(itemId: String) async throws {}
    func selectWholeVault(_ selected: Bool, vaultID: String) async throws {
        try await gates.vaultMutation.wait()
    }
    func updateSelectionObservation(generation: UUID, status: OfflineSelectionObservationStatus) async {}
    func keepOfflineIndividually(_ item: PassItem) async throws {
        promotions += 1
        try await gates.promotion.wait()
    }
    func promotionCount() -> Int { promotions }
    func retrySelectedCopies(vaultID: String?) async throws {}
    func metadataDidSynchronize(allowMembershipExpansion: Bool, eligibleItemIDs: Set<String>) async {}
    func waitUntilIdle() async {}
    func prepareForMetadataReset() async throws {}
    func finishMetadataReset() async {}
    func stop() async {}
    func removeAllOfflineData() async throws { try await gates.purge.wait() }
}

private actor CountingRecoveryRepository: OfflineSnapshotPersisting {
    private let base: OfflineSnapshotRepository
    nonisolated var releaseAuthority: OfflineReleaseAuthority { base.releaseAuthority }
    func releaseProof(for snapshot: EncryptedOfflineSnapshot) async throws -> OfflineReleaseProof? { try await base.releaseProof(for: snapshot) }
    private var recoveries = 0

    init(base: OfflineSnapshotRepository) { self.base = base }
    func recoveryCount() -> Int { recoveries }
    func beginRequest(itemID: String, vaultID: String, shareID: String, kind: OfflineRequestKind,
                      expectations: OfflineRequestExpectations) async throws -> OfflineRequestToken? {
        try await base.beginRequest(itemID: itemID, vaultID: vaultID, shareID: shareID, kind: kind,
                                    expectations: expectations)
    }
    func publish(_ snapshot: EncryptedOfflineSnapshot, for request: OfflineRequestToken, refreshedAt: Date) async throws -> Bool {
        try await base.publish(snapshot, for: request, refreshedAt: refreshedAt)
    }
    func finishRequest(_ request: OfflineRequestToken, failed: Bool) async throws { try await base.finishRequest(request, failed: failed) }
    func setVaultSelected(_ selected: Bool, vaultID: String) async throws -> OfflineVaultSelection? {
        try await base.setVaultSelected(selected, vaultID: vaultID)
    }
    func selectItemManually(itemID: String, vaultID: String, shareID: String) async throws -> UUID {
        try await base.selectItemManually(itemID: itemID, vaultID: vaultID, shareID: shareID)
    }
    func keepItemOfflineIndividually(itemID: String, vaultID: String) async throws {
        try await base.keepItemOfflineIndividually(itemID: itemID, vaultID: vaultID)
    }
    func itemPolicy(itemID: String, vaultID: String) async throws -> OfflineItemPolicy? {
        try await base.itemPolicy(itemID: itemID, vaultID: vaultID)
    }
    func workCandidates(vaultID: String?, includeNewSelections: Bool, refreshExisting: Bool) async throws -> [OfflineSnapshotWorkCandidate] {
        try await base.workCandidates(vaultID: vaultID, includeNewSelections: includeNewSelections, refreshExisting: refreshExisting)
    }
    func removeItem(_ itemID: String) async throws { try await base.removeItem(itemID) }
    func purge() async throws { try await base.purge() }
    func recoverAbandonedRequests() async throws {
        recoveries += 1
        if recoveries == 1 { throw OfflinePersistenceError.persistenceFailed }
        try await base.recoverAbandonedRequests()
    }
    func authorizedSnapshot(for key: OfflineSnapshotKey) async throws -> EncryptedOfflineSnapshot? {
        try await base.authorizedSnapshot(for: key)
    }
    func hasAuthorizedSnapshot(for key: OfflineSnapshotKey) async throws -> Bool { try await base.hasAuthorizedSnapshot(for: key) }
    func isAuthorized(_ snapshot: EncryptedOfflineSnapshot) async throws -> Bool { try await base.isAuthorized(snapshot) }
    func discardCorruptSnapshot(_ snapshot: EncryptedOfflineSnapshot) async throws { try await base.discardCorruptSnapshot(snapshot) }
    func hasPersistedSnapshots() async throws -> Bool { try await base.hasPersistedSnapshots() }
    func offlineVaultIds() async throws -> Set<String> { try await base.offlineVaultIds() }
    func offlineItemSelection(itemId: String) async throws -> OfflineItemSelection? {
        try await base.offlineItemSelection(itemId: itemId)
    }
    func offlineItemSelections() async throws -> [OfflineItemSelection] { try await base.offlineItemSelections() }
}

private actor LateReadinessService: OfflineModeServicing {
    private let gate: NonCancellableTestGate
    private var initializationCalls = 0
    private var retryCheckCalls = 0

    init(gate: NonCancellableTestGate) { self.gate = gate }

    func initialize() async throws {
        initializationCalls += 1
        if initializationCalls == 1 { throw TestObservationError.terminal }
    }

    func isReady() async -> Bool { initializationCalls > 1 }

    func requiresInitializationRetry() async -> Bool {
        retryCheckCalls += 1
        if retryCheckCalls == 1 {
            await gate.wait()
            return true
        }
        return false
    }

    func makeAvailableOffline(item: PassItem, shareId: String) async throws {}
    func removeOfflineItem(itemId: String) async throws {}
    func selectWholeVault(_ selected: Bool, vaultID: String) async throws {}
    func updateSelectionObservation(generation: UUID, status: OfflineSelectionObservationStatus) async {}
    func keepOfflineIndividually(_ item: PassItem) async throws {}
    func retrySelectedCopies(vaultID: String?) async throws {}
    func metadataDidSynchronize(allowMembershipExpansion: Bool, eligibleItemIDs: Set<String>) async {}
    func waitUntilIdle() async {}
    func prepareForMetadataReset() async throws {}
    func finishMetadataReset() async {}
    func stop() async {}
    func removeAllOfflineData() async throws {}
}
