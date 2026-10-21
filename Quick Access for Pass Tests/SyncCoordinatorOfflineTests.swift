import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("SyncCoordinator offline lifecycle", .timeLimit(.minutes(1)))
@MainActor
struct SyncCoordinatorOfflineTests {
    @Test("sync reuses complete list content without an item view")
    func syncReusesCompleteListPayloadForSelectedItem() async throws {
        let harness = try await makeHarness(selectedItemIDs: ["item"])
        let previousRefresh = try #require(harness.database.offlineItemSelection(itemId: "item")?.lastRefreshedAt)
        harness.coordinator.refreshNow()
        await harness.coordinator.currentSyncCompletion?.value
        #expect(try harness.database.offlineItemSelection(itemId: "item")?.lastRefreshedAt != previousRefresh)
        #expect(try await harness.repository.hasPersistedSnapshots())
        #expect(await harness.runner.viewRequests().isEmpty)
    }

    @Test("explicit Retry then matching coordinator sync adds zero item views")
    func matchingSyncAfterRetryAddsZeroViews() async throws {
        let harness = try await makeHarness(selectedItemIDs: ["item", "neighbor"])
        harness.coordinator.refreshNow()
        await harness.coordinator.currentSyncCompletion?.value
        #expect(await harness.runner.viewRequests().isEmpty)
        #expect(try await harness.service.retryOfflineItem(itemID: "item", vaultID: "vault") == .submitted)
        await harness.service.waitUntilIdle()
        #expect(await harness.runner.viewRequests() == ["pass://share/item"])
        let before = try #require(try await OfflinePersistedTestState.capture(database: harness.database, itemID: "item"))
        harness.coordinator.refreshNow()
        await harness.coordinator.currentSyncCompletion?.value
        #expect(await harness.runner.viewRequests() == ["pass://share/item"])
        #expect(try await OfflinePersistedTestState.capture(database: harness.database, itemID: "item") == before)
    }

    @Test("item-scoped retry remains limited to its selected sync identity")
    func itemRetryDoesNotRefreshHealthyNeighbor() async throws {
        let harness = try await makeHarness(selectedItemIDs: ["target", "neighbor"])
        let before = await harness.runner.viewRequests()
        #expect(try await harness.service.retryOfflineItem(itemID: "target", vaultID: "vault") == .submitted)
        await harness.service.waitUntilIdle()
        let after = await harness.runner.viewRequests()
        #expect(after.count == before.count + 1)
        #expect(after.last == "pass://share/target")
        #expect(try await harness.repository.offlineItemSelection(itemId: "neighbor")?.cacheStatus == .cached)
    }

    @Test("loading and native sync completion await future-item preparation")
    func successfulSyncAwaitsFutureVaultItemPreparation() async throws {
        let harness = try await makeHarness(selectedItemIDs: ["item"])
        try await harness.service.selectWholeVault(true, vaultID: "vault")
        await harness.service.waitUntilIdle()
        let preparationGate = IncrementalSyncGate()
        await harness.codec.setGate(preparationGate, itemIDs: ["new"])
        await harness.runner.setSyncedItemIDs(["item", "new"])
        let completion = OfflineSyncCompletionSignal()
        let coordinator = SyncCoordinator(
            cliService: harness.cliService, databaseManager: harness.database, viewModel: harness.viewModel,
            offlineModeService: harness.service,
            onSyncIssueChanged: { issue in if issue == nil { completion.complete() } }
        )
        coordinator.refreshNow()
        await preparationGate.waitUntilEntered()
        #expect(harness.viewModel.isLoading)
        #expect(completion.didComplete == false)
        #expect(try harness.database.allActiveItems().contains { $0.id == "new" })
        #expect(try harness.database.offlineItemSelection(itemId: "new")?.cacheStatus != .cached)
        await preparationGate.open()
        await coordinator.currentSyncCompletion?.value
        await harness.service.waitUntilIdle()
        await completion.wait()
        #expect(harness.viewModel.isLoading == false)
        #expect(try harness.database.offlineItemSelection(itemId: "new")?.cacheStatus == .cached)
        #expect(await harness.runner.viewRequests().isEmpty)
    }

    @Test("retry selected copies retries a failed cached refresh without changing selection origin")
    func retrySelectedCopiesRetriesFailedRefreshWithoutChangingOrigin() async throws {
        let harness = try await makeHarness(selectedItemIDs: ["item"])
        let beforeSelection = try harness.database.offlineItemSelection(itemId: "item")
        let before = try #require(beforeSelection)
        await harness.runner.setFailingItemIDs(["item"])
        await harness.service.metadataDidSynchronize(allowMembershipExpansion: false, eligibleItemIDs: ["item"])
        await harness.service.waitUntilIdle()
        let failedSelection = try harness.database.offlineItemSelection(itemId: "item")
        let failed = try #require(failedSelection)
        #expect(failed.cacheStatus == .failed)
        #expect(failed.lastRefreshedAt == before.lastRefreshedAt)

        await harness.runner.setFailingItemIDs([])
        let requestsBeforeRetry = await harness.runner.viewRequests().count
        try await harness.service.retrySelectedCopies(vaultID: "vault")
        await harness.service.waitUntilIdle()

        let retriedSelection = try harness.database.offlineItemSelection(itemId: "item")
        let retried = try #require(retriedSelection)
        #expect(await harness.runner.viewRequests().count > requestsBeforeRetry)
        #expect(retried.cacheStatus == .cached)
        #expect(retried.lastRefreshedAt != before.lastRefreshedAt)
        #expect(retried.isManuallySelected == before.isManuallySelected)
    }

    @Test("one selected-item refresh failure does not cancel healthy refreshes")
    func oneSelectedItemRefreshFailureDoesNotCancelOtherRefreshes() async throws {
        let harness = try await makeHarness(selectedItemIDs: ["failing", "healthy"], failingItemIDs: ["failing"], cliVersion: "2.4.1")
        let healthyPreviousRefresh = try #require(harness.database.offlineItemSelection(itemId: "healthy")?.lastRefreshedAt)
        let failingPreviousRefresh = try #require(harness.database.offlineItemSelection(itemId: "failing")?.lastRefreshedAt)
        let failingKey = OfflineSnapshotKey(vaultId: "vault", itemId: "failing", schemaVersion: OfflineSnapshotLimits.schemaVersion)
        let failingSnapshot = try #require(try await harness.repository.authorizedSnapshot(for: failingKey))
        harness.coordinator.refreshNow()
        #expect(await waitUntil {
            guard let healthy = try? harness.database.offlineItemSelection(itemId: "healthy"),
                  let failing = try? harness.database.offlineItemSelection(itemId: "failing") else { return false }
            return healthy.cacheStatus == .cached && healthy.lastRefreshedAt != healthyPreviousRefresh && failing.cacheStatus == .failed
        })
        let failingAfterRefresh = try #require(try await harness.repository.authorizedSnapshot(for: failingKey))
        let failingSelection = try #require(try harness.database.offlineItemSelection(itemId: "failing"))
        #expect(failingAfterRefresh.identity.revision == failingSnapshot.identity.revision)
        #expect(failingAfterRefresh.payload == failingSnapshot.payload)
        #expect(failingSelection.lastRefreshedAt == failingPreviousRefresh)
    }

    @Test("reset atomically purges snapshots before clearing metadata")
    func resetPurgesOfflineCacheBeforeClearingMetadata() async throws {
        let harness = try await makeHarness(selectedItemIDs: ["item"])
        harness.coordinator.resetAndSync()
        // The unified writer deletes `offlineItems`; the `offlineSnapshots` FK
        // cascades in the same transaction before transactional clearMetadata().
        #expect(await waitUntil { (try? harness.database.offlineItemSelection(itemId: "item")) == nil })
        #expect(try await harness.repository.hasPersistedSnapshots() == false)
    }

    @Test("reset revokes and joins paused preparation before metadata clear and reopens selection")
    func resetJoinsPausedPreparationBeforeMetadataClear() async throws {
        let harness = try await makeHarness(selectedItemIDs: [])
        try await harness.service.selectWholeVault(true, vaultID: "vault")
        try harness.database.upsertItems([offlineTestMetadata(id: "item", vaultID: "vault")])
        await harness.runner.setSyncedItemIDs(["item"])
        let preparationGate = OfflineNonCancellableGate()
        await harness.runner.setNonCancellableViewGate(preparationGate)
        await harness.service.metadataDidSynchronize(allowMembershipExpansion: true, eligibleItemIDs: ["item"])
        await preparationGate.waitUntilEntered()
        let resetSyncGate = OfflineTestGate()
        await harness.runner.holdNextSync(resetSyncGate)
        let completion = OfflineSyncCompletionSignal()
        let resetRecorder = OfflineResetRecorder()
        let coordinator = SyncCoordinator(
            cliService: harness.cliService, databaseManager: harness.database, viewModel: harness.viewModel,
            offlineModeService: harness.service,
            onResetInitiated: { resetRecorder.record() },
            onSyncIssueChanged: { issue in if issue == nil { completion.complete() } }
        )
        coordinator.resetAndSync()

        #expect(await waitUntil { (try? harness.database.offlineItemSelection(itemId: "item")) == nil })
        coordinator.resetAndSync()
        #expect(resetRecorder.count == 1, "A reset received during the active barrier should coalesce, not cancel/release it.")
        let currentBeforeJoin = try #require(try harness.database.allActiveItems().first { $0.id == "item" })
        await #expect(throws: OfflineModeService.Error.selectionSuspended) {
            try await harness.service.makeAvailableOffline(item: currentBeforeJoin, shareId: "share")
        }
        let metadataBeforeJoin = try harness.database.allActiveItems().map(\.id)
        #expect(metadataBeforeJoin.contains("item"), "Metadata must remain until paused preparation joins.")
        await preparationGate.open()
        try await resetSyncGate.waitUntilEntered()
        #expect(try harness.database.allActiveItems().isEmpty)
        #expect(try await harness.repository.hasPersistedSnapshots() == false)
        await resetSyncGate.open()
        await completion.wait()
        let current = try #require(try harness.database.allActiveItems().first { $0.id == "item" })
        try await harness.service.makeAvailableOffline(item: current, shareId: "share")
        #expect(try await harness.database.offlineItemSelection(itemId: "item")?.isManuallySelected == true)
        await harness.service.stop()
    }

    @Test("reset invokes transient-access revocation before its asynchronous purge")
    func resetInitiationRevokesBeforeOfflinePurge() async throws {
        let harness = try await makeHarness(selectedItemIDs: ["item"])
        let guardState = SecretReleaseGuard()
        let token = guardState.capture()
        let coordinator = SyncCoordinator(
            cliService: harness.cliService, databaseManager: harness.database, viewModel: harness.viewModel,
            offlineModeService: harness.service, onResetInitiated: { guardState.revoke() }
        )

        coordinator.resetAndSync()

        #expect(guardState.isCurrent(token) == false)
        #expect(await waitUntil { (try? harness.database.offlineItemSelection(itemId: "item")) == nil })
    }

}

extension SyncCoordinatorOfflineTests {
    @Test("committed missing-item sync deletion requests maintenance after its cascade")
    func committedMissingItemSyncDeletionRequestsMaintenance() async throws {
        let checkpointer = SyncCheckpointRecorder()
        let maintenance = OfflineStorageMaintenance(checkpointer: checkpointer, retryDelay: {})
        let harness = try await makeHarness(selectedItemIDs: ["item"], maintenance: maintenance)
        let coordinator = SyncCoordinator(
            cliService: harness.cliService, databaseManager: harness.database, viewModel: harness.viewModel,
            offlineModeService: harness.service, maintenance: maintenance
        )
        await harness.runner.setSyncedItemIDs([])

        coordinator.refreshNow()
        await checkpointer.waitForAttempt(1)

        #expect((try? harness.database.offlineItemSelection(itemId: "item")) == nil)
        #expect(try await harness.repository.hasPersistedSnapshots() == false)
        #expect(harness.viewModel.syncError == nil)
        await maintenance.stop()
    }

    @Test("committed stale-vault foreign-key cascade requests maintenance")
    func committedStaleVaultCascadeRequestsMaintenance() async throws {
        let checkpointer = SyncCheckpointRecorder()
        let maintenance = OfflineStorageMaintenance(checkpointer: checkpointer, retryDelay: {})
        let harness = try await makeHarness(selectedItemIDs: ["item"], maintenance: maintenance)
        let coordinator = SyncCoordinator(
            cliService: harness.cliService, databaseManager: harness.database, viewModel: harness.viewModel,
            offlineModeService: harness.service, maintenance: maintenance
        )
        await harness.runner.setIncludesVault(false)

        coordinator.refreshNow()
        await checkpointer.waitForAttempt(1)

        #expect(try harness.database.allVaults().isEmpty)
        #expect((try? harness.database.offlineItemSelection(itemId: "item")) == nil)
        #expect(try await harness.repository.hasPersistedSnapshots() == false)
        #expect(harness.viewModel.syncError == nil)
        await maintenance.stop()
    }

    @Test("reset purge requests maintenance before clearing unified metadata")
    func resetPurgeRequestsMaintenanceBeforeClearingMetadata() async throws {
        let checkpointer = SyncCheckpointRecorder()
        let maintenance = OfflineStorageMaintenance(checkpointer: checkpointer, retryDelay: {})
        let harness = try await makeHarness(selectedItemIDs: ["item"], maintenance: maintenance)
        let coordinator = SyncCoordinator(
            cliService: harness.cliService, databaseManager: harness.database, viewModel: harness.viewModel,
            offlineModeService: harness.service, maintenance: maintenance
        )

        coordinator.resetAndSync()
        await checkpointer.waitForAttempt(1)

        #expect((try? harness.database.offlineItemSelection(itemId: "item")) == nil)
        #expect(try await harness.repository.hasPersistedSnapshots() == false)
        await maintenance.stop()
    }

    @Test("rolled-back metadata deletion does not request maintenance")
    func rolledBackMetadataDeletionDoesNotRequestMaintenance() async throws {
        let checkpointer = SyncCheckpointRecorder()
        let maintenance = OfflineStorageMaintenance(checkpointer: checkpointer, retryDelay: {})
        let harness = try await makeHarness(selectedItemIDs: ["item"], maintenance: maintenance)
        let issueRecorder = OfflineSyncIssueRecorder()
        let coordinator = SyncCoordinator(
            cliService: harness.cliService, databaseManager: harness.database, viewModel: harness.viewModel,
            offlineModeService: harness.service, maintenance: maintenance,
            onSyncIssueChanged: { issueRecorder.issues.append($0) }
        )
        try await harness.database.writer.write { db in
            try db.execute(sql: """
            CREATE TRIGGER rejectSyncedItemDeletion BEFORE DELETE ON items
            BEGIN SELECT RAISE(ABORT, 'test'); END
            """)
        }
        await harness.runner.setSyncedItemIDs([])

        coordinator.refreshNow()
        #expect(await waitUntil { await issueRecorder.hasTerminalFailure() })
        #expect(await checkpointer.attemptCount() == 0)
        #expect(try await harness.repository.hasPersistedSnapshots())
        try await harness.database.writer.write { db in
            try db.execute(sql: "DROP TRIGGER rejectSyncedItemDeletion")
        }
        await maintenance.stop()
    }

    @Test("cancelling a superseded sync does not publish a sync failure")
    func cancellingBlockedRefreshDoesNotPublishSyncFailure() async throws {
        let gate = OfflineTestGate()
        let harness = try await makeHarness(selectedItemIDs: ["item"])
        let before = try #require(try await harness.repository.authorizedSnapshot(
            for: OfflineSnapshotKey(vaultId: "vault", itemId: "item", schemaVersion: OfflineSnapshotLimits.schemaVersion)))
        await harness.runner.holdNextSync(gate)
        let issueRecorder = OfflineSyncIssueRecorder()
        let coordinator = SyncCoordinator(
            cliService: harness.cliService, databaseManager: harness.database, viewModel: harness.viewModel,
            offlineModeService: harness.service, onSyncIssueChanged: { issueRecorder.issues.append($0) }
        )
        coordinator.refreshNow()
        do {
            try await gate.waitUntilEntered()
            let oldCompletion = coordinator.currentSyncCompletion
            coordinator.refreshNow()
            await gate.open()
            await coordinator.currentSyncCompletion?.value
            await oldCompletion?.value
            #expect(await waitUntil { await issueRecorder.hasNoFailure() })
            #expect(await harness.runner.viewRequests().isEmpty)
            let after = try #require(try await harness.repository.authorizedSnapshot(for: before.identity.key))
            #expect(after.identity.revision != before.identity.revision)
            #expect(try await harness.database.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM offlineSyncCaptures") } == 0)
            #expect(harness.viewModel.syncError == nil)
        } catch {
            // The coordinator owns its task; releasing the gate lets its
            // cancelled/superseding work complete before this test exits.
            await gate.open()
            throw error
        }
    }

    @Test("automatic refresh retains unsupported current-key ciphertext without reserving or fetching")
    func automaticRefreshRetainsUnsupportedCurrentKeySnapshot() async throws {
        let harness = try await makeHarness(selectedItemIDs: ["item"])
        let pendingID = UUID().uuidString
        try await harness.database.writer.write { db in
            try db.execute(sql: "UPDATE offlineSnapshots SET schemaVersion = 2 WHERE itemId = 'item'")
            try db.execute(sql: "UPDATE offlineItems SET pendingRequestId = ? WHERE itemId = 'item'", arguments: [pendingID])
        }
        let before = try #require(try await OfflinePersistedTestState.capture(database: harness.database, itemID: "item"))
        await harness.service.refreshSelectedSnapshots(
            vaults: [PassVault(id: "vault", name: "Vault", shareId: "share")], items: [offlineTestMetadata(id: "item", vaultID: "vault")]
        )
        await harness.service.waitUntilIdle()
        #expect(try await OfflinePersistedTestState.capture(database: harness.database, itemID: "item") == before)
        #expect(await harness.runner.viewRequests().isEmpty)
        try await harness.service.removeOfflineItem(itemId: "item")
        #expect(try await OfflinePersistedTestState.capture(database: harness.database, itemID: "item") == nil)
        try await harness.service.removeAllOfflineData()
        #expect(try await harness.repository.offlineVaultIds().isEmpty)
    }

    @Test("lossy present item retains exact selected snapshot while healthy neighbor syncs", arguments: [false, true])
    func lossyPresentItemRetainsSnapshot(unknownItemID: Bool) async throws {
        let harness = try await makeHarness(selectedItemIDs: ["item", "healthy", "missing"])
        await harness.runner.setSyncedItemIDs(["item", "healthy"])
        let descriptor = try #require(try harness.database.syncMetadata(
            vaults: [PassVault(id: "vault", name: "Vault", shareId: "share")], items: harness.database.allActiveItems(),
            descriptors: [AutoFillDescriptorInput(
                vaultID: "vault", itemID: "item", shareID: "share", title: "Previously verified", username: "user",
                serviceIdentifier: "example.test", hasTOTP: false
            )]
        ).first)
        let associations = AutoFillAppAssociationStore(databaseManager: harness.database)
        try await associations.save(service: AutoFillServiceIdentifier(kind: .app, identifier: "test.previous", displayName: nil), descriptorID: descriptor.id, createdAt: .distantPast)
        let missingBefore = try #require(try await OfflinePersistedTestState.capture(database: harness.database, itemID: "missing"))
        let pendingID = UUID().uuidString
        try await harness.database.writer.write { db in
            try db.execute(sql: "UPDATE offlineItems SET pendingRequestId = ? WHERE itemId = 'item'", arguments: [pendingID])
        }
        let before = try #require(try await OfflinePersistedTestState.capture(database: harness.database, itemID: "item"))
        let oldMetadata = try #require(try harness.database.allActiveItems().first { $0.id == "item" })
        let healthyBefore = try #require(try harness.database.offlineItemSelection(itemId: "healthy")?.lastRefreshedAt)
        let malformed = unknownItemID ? "{\"share_id\":\"untrusted-share\",\"content\":false}" : "{\"id\":\"item\",\"share_id\":\"untrusted-share\",\"content\":false}"
        await harness.runner.setMalformedListEntry(malformed, replacing: "item")
        let issues = OfflineSyncIssueRecorder()
        let coordinator = SyncCoordinator(
            cliService: harness.cliService, databaseManager: harness.database, viewModel: harness.viewModel,
            offlineModeService: harness.service, onSyncIssueChanged: { issues.issues.append($0) }
        )
        coordinator.refreshNow()
        #expect(await waitUntil { await MainActor.run { !issues.issues.isEmpty } })
        await harness.service.waitUntilIdle()
        #expect(harness.viewModel.syncError == nil)
        #expect(harness.viewModel.skippedSyncItems != nil)
        #expect(try await OfflinePersistedTestState.capture(database: harness.database, itemID: "item") == before)
        let retained = try #require(try harness.database.allActiveItems().first { $0.id == "item" })
        #expect(retained.vaultId == oldMetadata.vaultId)
        #expect(retained.title == oldMetadata.title)
        #expect(retained.modifyTime == oldMetadata.modifyTime)
        #expect(try harness.database.offlineItemSelection(itemId: "healthy")?.lastRefreshedAt != healthyBefore)
        #expect(await harness.runner.viewRequests() == ["pass://share/healthy"])
        #expect(try harness.database.allAutoFillDescriptors().isEmpty)
        #expect(try await associations.associations().isEmpty)
        let missingAfter = try await OfflinePersistedTestState.capture(database: harness.database, itemID: "missing")
        #expect(missingAfter == (unknownItemID ? missingBefore : nil))
    }

    @Test("unknown-ID uncertainty is vault scoped; decoded inactive/moved and removed vault still prune")
    func unidentifiedSkipRetainsOnlyUncertainVaultWhileConfirmedRemovalsCommit() async throws {
        let checkpointer = SyncCheckpointRecorder()
        let maintenance = OfflineStorageMaintenance(checkpointer: checkpointer, retryDelay: {})
        let harness = try await makeHarness(selectedItemIDs: ["item", "inactive", "moved"], maintenance: maintenance)
        let extraVaults = [PassVault(id: "healthy-vault", name: "Healthy", shareId: "healthy-share"), PassVault(id: "removed-vault", name: "Removed", shareId: "removed-share")]
        try harness.database.upsertVaults(extraVaults)
        let extraItems = [offlineTestMetadata(id: "missing", vaultID: "healthy-vault"), offlineTestMetadata(id: "removed", vaultID: "removed-vault")]
        try harness.database.upsertItems(extraItems)
        let codec = OfflineSnapshotCodec(keyMaterialProvider: OfflineFixtureKeys(), hasPersistedSnapshots: { try await harness.repository.hasPersistedSnapshots() })
        for item in extraItems {
            let shareID = item.vaultId == "healthy-vault" ? "healthy-share" : "removed-share"
            _ = try await harness.repository.setVaultSelected(true, vaultID: item.vaultId)
            let request = try #require(try await harness.repository.beginRequest(itemID: item.id, vaultID: item.vaultId, shareID: shareID, kind: .selection))
            let snapshot = try await codec.prepareSnapshot(from: offlineTestCLIItem(id: item.id, vaultID: item.vaultId, shareID: shareID, password: "fake"), for: request)
            #expect(try await harness.repository.publish(snapshot, for: request, refreshedAt: .distantPast))
        }
        let before = try #require(try await OfflinePersistedTestState.capture(database: harness.database, itemID: "item"))
        let inactive = try offlineTestCLIItem(id: "inactive", vaultID: "vault", shareID: "share", password: "fake")
        let inactiveJSON = String(decoding: try JSONEncoder().encode(inactive), as: UTF8.self).replacingOccurrences(of: "\"Active\"", with: "\"Trashed\"")
        let movedJSON = String(decoding: try JSONEncoder().encode(offlineTestCLIItem(id: "moved", vaultID: "healthy-vault", shareID: "healthy-share", password: "fake")), as: UTF8.self)
        await harness.runner.setSyncResponse(
            vaults: "{\"vaults\":[{\"name\":\"Vault\",\"vault_id\":\"vault\",\"share_id\":\"share\"},{\"name\":\"Healthy\",\"vault_id\":\"healthy-vault\",\"share_id\":\"healthy-share\"}]}",
            lists: ["share": "{\"items\":[{\"content\":false,\"share_id\":\"healthy-share\"},\(inactiveJSON)]}", "healthy-share": "{\"items\":[\(movedJSON)]}"]
        )
        let issues = OfflineSyncIssueRecorder()
        let coordinator = SyncCoordinator(
            cliService: harness.cliService, databaseManager: harness.database, viewModel: harness.viewModel,
            offlineModeService: harness.service, maintenance: maintenance, onSyncIssueChanged: { issues.issues.append($0) }
        )
        coordinator.refreshNow()
        #expect(await waitUntil { await MainActor.run { !issues.issues.isEmpty } })
        #expect(harness.viewModel.syncError == nil)
        #expect(try await OfflinePersistedTestState.capture(database: harness.database, itemID: "item") == before)
        for itemID in ["missing", "inactive", "moved", "removed"] {
            #expect(try harness.database.offlineItemSelection(itemId: itemID) == nil)
        }
        #expect(try harness.database.allActiveItems().first { $0.id == "moved" }?.vaultId == "healthy-vault")
        #expect(try harness.database.allVaults().contains { $0.id == "removed-vault" } == false)
        #expect(await checkpointer.attemptCount() >= 1)
        await maintenance.stop()
    }

    @Test("incomplete-vault sync rollback retains both skipped and confirmed-missing snapshots without maintenance")
    func lossySyncRollbackDoesNotDeleteOrRequestMaintenance() async throws {
        let checkpointer = SyncCheckpointRecorder()
        let maintenance = OfflineStorageMaintenance(checkpointer: checkpointer, retryDelay: {})
        let harness = try await makeHarness(selectedItemIDs: ["item", "missing"], maintenance: maintenance)
        let itemBefore = try #require(try await OfflinePersistedTestState.capture(database: harness.database, itemID: "item"))
        let missingBefore = try #require(try await OfflinePersistedTestState.capture(database: harness.database, itemID: "missing"))
        await harness.runner.setSyncedItemIDs(["item"])
        await harness.runner.setMalformedListEntry("{\"id\":\"item\",\"content\":false}", replacing: "item")
        try await harness.database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER rejectConfirmedDeletion BEFORE DELETE ON items WHEN OLD.id = 'missing'
                BEGIN SELECT RAISE(ABORT, 'test'); END
                """)
        }
        let issues = OfflineSyncIssueRecorder()
        let coordinator = SyncCoordinator(
            cliService: harness.cliService, databaseManager: harness.database, viewModel: harness.viewModel,
            offlineModeService: harness.service, maintenance: maintenance, onSyncIssueChanged: { issues.issues.append($0) }
        )
        coordinator.refreshNow()
        #expect(await waitUntil { await issues.hasTerminalFailure() })
        #expect(try await OfflinePersistedTestState.capture(database: harness.database, itemID: "item") == itemBefore)
        #expect(try await OfflinePersistedTestState.capture(database: harness.database, itemID: "missing") == missingBefore)
        #expect(await checkpointer.attemptCount() == 0)
        await maintenance.stop()
    }

    private func makeHarness(
        selectedItemIDs: [String],
        failingItemIDs: Set<String> = [],
        publicationGate: OfflineTestGate? = nil,
        maintenance: OfflineStorageMaintenance? = nil,
        cliVersion: String = "2.4.2"
    ) async throws -> OfflineLifecycleHarness {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let itemIDs = Array(Set(selectedItemIDs).union(failingItemIDs)).sorted()
        let items = itemIDs.map { offlineTestMetadata(id: $0, vaultID: "vault") }
        try database.upsertVaults([PassVault(id: "vault", name: "Vault", shareId: "share")])
        try database.upsertItems(items)
        let publicationControl = OfflinePublicationControl(gate: publicationGate)
        let repository = OfflineSnapshotRepository(database: database, beforePublication: {
            await publicationControl.waitIfEnabled()
        }, maintenance: maintenance)
        let runner = OfflineLifecycleRunner(itemIDs: itemIDs, failingItemIDs: failingItemIDs, cliVersion: cliVersion)
        let cliService = PassCLIService(cliPath: "/usr/bin/pass", runner: runner)
        let codec = IncrementalSyncCodec(base: OfflineSnapshotCodec(keyMaterialProvider: OfflineFixtureKeys(), hasPersistedSnapshots: { try await repository.hasPersistedSnapshots() }))
        let service = OfflineModeService(repository: repository, codec: codec, cliService: cliService)
        try await initializeOfflineFixtureService(service)
        for item in items where selectedItemIDs.contains(item.id) { try await service.makeAvailableOffline(item: item, shareId: "share") }
        await publicationControl.enable()
        await runner.beginRefresh()
        let viewModel = QuickAccessViewModel(
            searchService: SearchService(databaseManager: database), cliService: cliService,
            clipboardManager: ClipboardManager(autoClearSeconds: 0), onDismiss: {},
            writeStringToPasteboard: { _ in }, openURL: { _ in true }
        )
        let coordinator = SyncCoordinator(
            cliService: cliService, databaseManager: database, viewModel: viewModel,
            offlineModeService: service, maintenance: maintenance
        )
        return OfflineLifecycleHarness(database: database, repository: repository, cliService: cliService, service: service,
                                       runner: runner, codec: codec, viewModel: viewModel, coordinator: coordinator)
    }
}

extension SyncCoordinatorOfflineTests {
    @Test("incomplete sync does not select decoded future item or refresh retained uncertain row")
    func incompleteSyncDoesNotExpandVaultMembershipFromUncertainRows() async throws {
        let harness = try await makeHarness(selectedItemIDs: [])
        try await harness.service.selectWholeVault(true, vaultID: "vault")
        await harness.service.waitUntilIdle()
        try harness.database.upsertItems([offlineTestMetadata(id: "uncertain", vaultID: "vault")])
        await harness.runner.setSyncedItemIDs(["uncertain", "new"])
        await harness.runner.setMalformedListEntry("{\"id\":\"uncertain\",\"content\":false}", replacing: "uncertain")
        let completion = OfflineSyncCompletionSignal()
        let coordinator = SyncCoordinator(
            cliService: harness.cliService, databaseManager: harness.database, viewModel: harness.viewModel,
            offlineModeService: harness.service,
            onSyncIssueChanged: { _ in completion.complete() }
        )

        coordinator.refreshNow()
        await completion.wait()
        await harness.service.waitUntilIdle()

        #expect(harness.viewModel.syncError == nil)
        #expect(harness.viewModel.skippedSyncItems != nil)
        #expect(try harness.database.allActiveItems().contains { $0.id == "uncertain" })
        #expect(try harness.database.allActiveItems().contains { $0.id == "new" })
        #expect(try await harness.repository.offlineItemSelection(itemId: "new") == nil)
        #expect(await harness.runner.viewRequests().contains("pass://share/new") == false)
        #expect(await harness.runner.viewRequests().contains("pass://share/uncertain") == false)
    }
}

extension SyncCoordinatorOfflineTests {
    @Test("readiness recovered during fetch cannot admit its already-started operation", arguments: [false, true])
    func readinessDuringFetchCannotGainAdmission(initiallyUninitialized: Bool) async throws {
        let harness = try await makeHarness(selectedItemIDs: ["item"])
        let key = OfflineSnapshotKey(vaultId: "vault", itemId: "item", schemaVersion: OfflineSnapshotLimits.schemaVersion)
        let before = try #require(try await harness.repository.authorizedSnapshot(for: key))
        let service: OfflineModeService
        if initiallyUninitialized {
            service = OfflineModeService(repository: harness.repository, codec: harness.codec, cliService: harness.cliService)
        } else {
            service = harness.service
            await service.updateSelectionObservation(generation: offlineFixtureObservationGeneration, status: .failed)
        }
        let gate = OfflineNonCancellableGate()
        await harness.runner.holdNextList(gate)
        let coordinator = SyncCoordinator(cliService: harness.cliService, databaseManager: harness.database,
                                          viewModel: harness.viewModel, offlineModeService: service)
        coordinator.refreshNow()
        await gate.waitUntilEntered()
        if initiallyUninitialized { try await initializeOfflineFixtureService(service) }
        else { await service.updateSelectionObservation(generation: offlineFixtureObservationGeneration, status: .fresh) }
        await gate.open()
        await coordinator.currentSyncCompletion?.value
        #expect(try harness.database.allActiveItems().first?.title == "item")
        #expect(try await harness.repository.authorizedSnapshot(for: key) == before)
        #expect(await harness.runner.viewRequests().isEmpty)
        #expect(harness.viewModel.syncError == nil)
        #expect(try await harness.database.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM offlineSyncCaptures") } == 0)
    }

    @Test("fetch failures join capture cleanup without changing a selected snapshot", arguments: [
        CLIError.notInstalled, .notLoggedIn, .timeout, .parseError("synthetic parse failure"),
        .commandFailed("synthetic fetch failure"), .commandFailed("Error decrypting local session: synthetic")
    ])
    func fetchErrorsAlwaysJoinCaptureCleanup(error: CLIError) async throws {
        let harness = try await makeHarness(selectedItemIDs: ["item"])
        let before = try #require(try await OfflinePersistedTestState.capture(database: harness.database, itemID: "item"))
        await harness.runner.setSyncFailure(error)
        harness.coordinator.refreshNow()
        await harness.coordinator.currentSyncCompletion?.value
        #expect(try await OfflinePersistedTestState.capture(database: harness.database, itemID: "item") == before)
        #expect(try await harness.database.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM offlineSyncCaptures") } == 0)
        #expect(harness.viewModel.isLoading == false)
        if error.isNotInstalled { #expect(harness.viewModel.errorMessage != nil) }
        else { #expect(harness.viewModel.syncError != nil) }
        #expect(await harness.runner.viewRequests().isEmpty)
    }

    @Test("reset purges before joining bulk preparation and clears metadata only after its frame joins")
    func resetJoinsBulkPreparationBeforeMetadataClear() async throws {
        let harness = try await makeHarness(selectedItemIDs: ["item"])
        let preparation = IncrementalSyncGate()
        await harness.codec.setGate(preparation)
        harness.coordinator.refreshNow()
        await preparation.waitUntilEntered()
        let oldCompletion = harness.coordinator.currentSyncCompletion
        let resetFetch = OfflineTestGate()
        await harness.runner.holdNextSync(resetFetch)
        harness.coordinator.resetAndSync()
        #expect(await waitUntil { (try? harness.database.offlineItemSelection(itemId: "item")) == nil })
        #expect(try harness.database.allActiveItems().contains { $0.id == "item" }, "Purge must commit before join; metadata clear must wait for the owned bulk frame.")
        await preparation.open()
        await oldCompletion?.value
        try await resetFetch.waitUntilEntered()
        #expect(try harness.database.allActiveItems().isEmpty)
        #expect(try await harness.repository.hasPersistedSnapshots() == false)
        await resetFetch.open()
        await harness.coordinator.currentSyncCompletion?.value
        #expect(try harness.database.offlineItemSelection(itemId: "item") == nil)
    }

    @Test("removal and purge commit while non-cancellable list fetch is held", arguments: [false, true])
    func revocationWhileListFetchIsHeldCannotResurrect(purge: Bool) async throws {
        let harness = try await makeHarness(selectedItemIDs: ["item", "other"])
        let gate = OfflineNonCancellableGate()
        await harness.runner.holdNextList(gate)
        harness.coordinator.refreshNow()
        await gate.waitUntilEntered()
        #expect(try await harness.database.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM offlineSyncCaptures") } == 1)
        if purge { try await harness.service.removeAllOfflineData() }
        else { try await harness.service.removeOfflineItem(itemId: "item") }
        #expect(try harness.database.offlineItemSelection(itemId: "item") == nil)
        await gate.open()
        await harness.coordinator.currentSyncCompletion?.value
        #expect(try harness.database.offlineItemSelection(itemId: "item") == nil)
        let other = try harness.database.offlineItemSelection(itemId: "other")
        if purge { #expect(other == nil) }
        else { #expect(other?.cacheStatus == .cached) }
        #expect(await harness.runner.viewRequests().isEmpty)
        #expect(harness.viewModel.syncError == nil)
    }
}

private struct OfflineLifecycleHarness {
    let database: DatabaseManager
    let repository: OfflineSnapshotRepository
    let cliService: PassCLIService
    let service: OfflineModeService
    let runner: OfflineLifecycleRunner
    let codec: IncrementalSyncCodec
    let viewModel: QuickAccessViewModel
    let coordinator: SyncCoordinator
}

private actor OfflineNonCancellableGate {
    private var isOpen = false
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        let entries = entryWaiters
        entryWaiters.removeAll()
        entries.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func open() {
        isOpen = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}

private actor OfflineLifecycleRunner: CLIRunning {
    private var itemIDs: [String]
    private let cliVersion: String
    private var failingItemIDs: Set<String>
    private var includesVault = true
    private var requests: [String] = []
    private var isRefreshing = false
    private var malformedEntry: (json: String, itemID: String)?
    private var syncVaults: String?
    private var syncFailure: CLIError?
    private var syncLists: [String: String] = [:]
    private var nextSyncGate: OfflineTestGate?
    private var nextListGate: OfflineNonCancellableGate?
    private var viewGate: OfflineTestGate?
    private var nonCancellableViewGate: OfflineNonCancellableGate?
    init(itemIDs: [String], failingItemIDs: Set<String>, cliVersion: String) {
        self.itemIDs = itemIDs
        self.failingItemIDs = failingItemIDs
        self.cliVersion = cliVersion
    }
    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        if arguments == ["--version"] { return Data("pass-cli \(cliVersion)".utf8) }
        if arguments == ["vault", "list", "--output", "json"] {
            if let gate = nextSyncGate {
                nextSyncGate = nil
                try? await gate.wait()
            }
            if let syncFailure { throw syncFailure }
            if let syncVaults { return Data(syncVaults.utf8) }
            return Data((includesVault
                ? "{\"vaults\":[{\"name\":\"Vault\",\"vault_id\":\"vault\",\"share_id\":\"share\"}]}"
                : "{\"vaults\":[]}").utf8)
        }
        if arguments.starts(with: ["item", "list"]) {
            if let option = arguments.first(where: { $0.hasPrefix("--share-id=") }), let list = syncLists[String(option.dropFirst("--share-id=".count))] {
                return Data(list.utf8)
            }
            let entries = itemIDs.map { id in malformedEntry?.itemID == id ? malformedEntry!.json : itemJSON(id) }
            let result = Data("{\"items\":[\(entries.joined(separator: ","))]}".utf8)
            if let gate = nextListGate { nextListGate = nil; await gate.wait() }
            return result
        }
        if arguments.starts(with: ["item", "view"]), let uri = arguments.last {
            requests.append(uri)
            if let viewGate { try? await viewGate.wait() }
            if let nonCancellableViewGate { await nonCancellableViewGate.wait() }
            let itemID = String(uri.split(separator: "/").last!)
            if isRefreshing && failingItemIDs.contains(itemID) { throw CLIError.commandFailed("unavailable") }
            return Data("{\"item\":\(itemJSON(itemID))}".utf8)
        }
        throw CLIError.commandFailed("unexpected command")
    }
    func beginRefresh() { isRefreshing = true; requests.removeAll() }
    func setFailingItemIDs(_ itemIDs: Set<String>) { failingItemIDs = itemIDs }
    func setSyncFailure(_ error: CLIError?) { syncFailure = error }
    func holdNextSync(_ gate: OfflineTestGate) { nextSyncGate = gate }
    func holdNextList(_ gate: OfflineNonCancellableGate) { nextListGate = gate }
    func setViewGate(_ gate: OfflineTestGate?) { viewGate = gate }
    func setNonCancellableViewGate(_ gate: OfflineNonCancellableGate?) { nonCancellableViewGate = gate }
    func setMalformedListEntry(_ json: String, replacing itemID: String) { malformedEntry = (json, itemID) }
    func setSyncResponse(vaults: String, lists: [String: String]) { syncVaults = vaults; syncLists = lists }
    func setSyncedItemIDs(_ ids: [String]) { itemIDs = ids }
    func setIncludesVault(_ value: Bool) { includesVault = value }
    func viewRequests() -> [String] { requests }
    private nonisolated func itemJSON(_ id: String) -> String {
        guard let item = try? incrementalSyncCLIItem(id: id, password: "fake-password", title: id),
              let data = try? JSONEncoder().encode(item) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor private final class OfflineResetRecorder {
    private(set) var count = 0
    func record() { count += 1 }
}

@MainActor private final class OfflineSyncCompletionSignal {
    private(set) var didComplete = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func complete() {
        didComplete = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }

    func wait() async {
        guard !didComplete else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@MainActor private final class OfflineSyncIssueRecorder {
    var issues: [QuickAccessSyncIssuePresentation?] = []
    func isOnlySuccess() -> Bool { issues == [nil] }
    func hasNoFailure() -> Bool { !issues.isEmpty && issues.allSatisfy { $0 == nil } }
    func hasTerminalFailure() -> Bool { issues.contains { $0 != nil } }
}

private actor SyncCheckpointRecorder: OfflineCheckpointing {
    private var attempts = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func checkpoint() async throws -> OfflineCheckpointResult {
        attempts += 1
        let ready = waiters.filter { attempts >= $0.0 }
        waiters.removeAll { attempts >= $0.0 }
        for (_, continuation) in ready { continuation.resume() }
        return .complete
    }

    func waitForAttempt(_ expected: Int) async {
        guard attempts < expected else { return }
        await withCheckedContinuation { waiters.append((expected, $0)) }
    }

    func attemptCount() -> Int { attempts }
}

private actor OfflinePublicationControl {
    private let gate: OfflineTestGate?
    private var enabled = false
    init(gate: OfflineTestGate?) { self.gate = gate }
    func enable() { enabled = true }
    func waitIfEnabled() async {
        guard enabled, let gate else { return }
        try? await gate.wait()
    }
}

private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<200 { if await condition() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
    return false
}
