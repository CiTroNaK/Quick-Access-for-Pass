@preconcurrency import Dispatch
import Foundation
import GRDB
import Synchronization
import Testing
@testable import Quick_Access_for_Pass

// The concurrency regression keeps its deterministic executor and queue gates local.
// swiftlint:disable file_length

@Suite("Offline snapshot repository")
struct OfflineSnapshotRepositoryTests {




















    @Test func publicationRefusesFutureSchemaReplacementAfterSupportedReservation() async throws {
        let fixture = try OfflineRepositoryFixture(itemIDs: ["item"])
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        let initial = try #require(try await fixture.repository.beginRequest(itemID: "item", vaultID: "vault", shareID: "share", kind: .selection))
        #expect(try await fixture.repository.publish(try fixture.snapshot(for: initial, password: "old"), for: initial, refreshedAt: .distantPast))
        let refresh = try #require(try await fixture.repository.beginRequest(itemID: "item", vaultID: "vault", shareID: "share", kind: .refresh))
        let revision = UUID().uuidString
        let replacementPayload = Data(repeating: 8, count: 40)
        try await fixture.database.writer.write { db in
            try db.execute(sql: "UPDATE offlineSnapshots SET schemaVersion = 2, snapshotRevision = ?, encryptedPayload = ? WHERE itemId = 'item'",
                           arguments: [revision, replacementPayload])
        }
        let replacement = try #require(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item"))
        #expect(try await fixture.repository.publish(try fixture.snapshot(for: refresh, password: "new"), for: refresh, refreshedAt: .now) == false)
        #expect(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item") == replacement)
        try await fixture.repository.purge()
        #expect(try await fixture.repository.hasPersistedSnapshots() == false)
    }



    @Test func refreshCannotReserveStructurallyInvalidRevision() async throws {
        let fixture = try OfflineRepositoryFixture(itemIDs: ["item"])
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        let initial = try #require(try await fixture.repository.beginRequest(itemID: "item", vaultID: "vault", shareID: "share", kind: .selection))
        #expect(try await fixture.repository.publish(try fixture.snapshot(for: initial, password: "fake"), for: initial, refreshedAt: .distantPast))
        try await fixture.database.writer.write { db in
            try db.execute(sql: "UPDATE offlineSnapshots SET snapshotRevision = 'unusable-revision' WHERE itemId = 'item'")
        }
        let before = try #require(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item"))
        #expect(try await fixture.repository.beginRequest(itemID: "item", vaultID: "vault", shareID: "share", kind: .refresh) == nil)
        #expect(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item") == before)
    }

    @Test func latePublicationCannotResurrectPurgedSelection() async throws {
        let fixture = try OfflineRepositoryFixture(itemIDs: ["item"])
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        let request = try #require(try await fixture.repository.beginRequest(
            itemID: "item", vaultID: "vault", shareID: "share", kind: .selection
        ))
        let snapshot = try fixture.snapshot(for: request, password: "fake-password")

        try await fixture.repository.purge()

        #expect(try await fixture.repository.publish(snapshot, for: request, refreshedAt: Date()) == false)
        #expect(try await fixture.repository.hasPersistedSnapshots() == false)
    }



    @Test func removingBCannotInvalidateRefreshForA() async throws {
        let fixture = try OfflineRepositoryFixture(itemIDs: ["a", "b"])
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        let initial = try #require(try await fixture.repository.beginRequest(
            itemID: "a", vaultID: "vault", shareID: "share", kind: .selection
        ))
        #expect(try await fixture.repository.publish(try fixture.snapshot(for: initial, password: "old"), for: initial, refreshedAt: .now))
        let refresh = try #require(try await fixture.repository.beginRequest(
            itemID: "a", vaultID: "vault", shareID: "share", kind: .refresh
        ))

        try await fixture.repository.removeItem("b")

        #expect(try await fixture.repository.publish(try fixture.snapshot(for: refresh, password: "new"), for: refresh, refreshedAt: .now))
        #expect(try await fixture.repository.hasAuthorizedSnapshot(for: refresh.key))
    }

    @Test func removingAndReselectingSameItemRejectsOldRequest() async throws {
        let fixture = try OfflineRepositoryFixture(itemIDs: ["item"])
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        let old = try #require(try await fixture.repository.beginRequest(
            itemID: "item", vaultID: "vault", shareID: "share", kind: .selection
        ))
        try await fixture.repository.removeItem("item")
        let current = try #require(try await fixture.repository.beginRequest(
            itemID: "item", vaultID: "vault", shareID: "share", kind: .selection
        ))

        #expect(try await fixture.repository.publish(try fixture.snapshot(for: old, password: "old"), for: old, refreshedAt: .now) == false)
        #expect(try await fixture.repository.publish(try fixture.snapshot(for: current, password: "new"), for: current, refreshedAt: .now))
    }

    @Test func supersededRequestCannotChangeNewerRequestOrSnapshot() async throws {
        let fixture = try OfflineRepositoryFixture(itemIDs: ["item"])
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        let first = try #require(try await fixture.repository.beginRequest(
            itemID: "item", vaultID: "vault", shareID: "share", kind: .selection
        ))
        let second = try #require(try await fixture.repository.beginRequest(
            itemID: "item", vaultID: "vault", shareID: "share", kind: .selection
        ))

        try await fixture.repository.finishRequest(first, failed: true)
        #expect(try await fixture.repository.publish(try fixture.snapshot(for: first, password: "first"), for: first, refreshedAt: .now) == false)
        #expect(try await fixture.repository.publish(try fixture.snapshot(for: second, password: "second"), for: second, refreshedAt: .now))
        #expect(try await fixture.repository.hasAuthorizedSnapshot(for: second.key))
    }

    @Test func metadataOrShareChangesRejectPublication() async throws {
        let fixture = try OfflineRepositoryFixture(itemIDs: ["item"])
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        let request = try #require(try await fixture.repository.beginRequest(
            itemID: "item", vaultID: "vault", shareID: "share", kind: .selection
        ))
        _ = try fixture.database.syncMetadata(
            vaults: [PassVault(id: "vault", name: "Vault", shareId: "rotated-share")],
            items: [offlineTestMetadata(id: "item", vaultID: "vault", modifyTime: Date(timeIntervalSince1970: 3))],
            descriptors: []
        )

        #expect(try await fixture.repository.publish(try fixture.snapshot(for: request, password: "fake"), for: request, refreshedAt: .now) == false)
    }

    @Test func itemTypeChangeRejectsPublication() async throws {
        let fixture = try OfflineRepositoryFixture(itemIDs: ["item"])
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        let request = try #require(try await fixture.repository.beginRequest(
            itemID: "item", vaultID: "vault", shareID: "share", kind: .selection
        ))
        let changedType = PassItem(
            id: "item", vaultId: "vault", title: "Offline example", itemType: .note,
            subtitle: "", url: nil, hasTOTP: false, state: "Active",
            createTime: Date(timeIntervalSince1970: 1), modifyTime: request.metadataModifyTime,
            useCount: 0, lastUsedAt: nil
        )
        _ = try fixture.database.syncMetadata(
            vaults: [PassVault(id: "vault", name: "Vault", shareId: "share")],
            items: [changedType],
            descriptors: []
        )

        #expect(try await fixture.repository.publish(try fixture.snapshot(for: request, password: "fake"), for: request, refreshedAt: .now) == false)
    }

    @Test func cancellingWriterQueuedPublicationDoesNotWriteSnapshot() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("offline-repository-test".utf8))
        try database.upsertVaults([PassVault(id: "vault", name: "Vault", shareId: "share")])
        try database.upsertItems([offlineTestMetadata(id: "item", vaultID: "vault")])
        let marker = PublicationSubmissionMarker()
        let publisherExecutor = PublisherTaskExecutor(marker: marker)
        let repository = OfflineSnapshotRepository(
            database: database,
            publicationSubmissionMarker: { marker.markSubmitted() }
        )
        let fixture = OfflineRepositoryFixture(database: database, repository: repository)
        _ = try await repository.setVaultSelected(true, vaultID: "vault")
        let request = try #require(try await repository.beginRequest(
            itemID: "item", vaultID: "vault", shareID: "share", kind: .selection
        ))
        let snapshot = try fixture.snapshot(for: request, password: "fake")
        let blocker = WriterQueueBlocker()
        let holder = Task {
            try await database.writer.write { _ in
                blocker.holdWriterQueue()
            }
        }
        await blocker.waitUntilWriterQueueIsHeld()
        let publication = Task(executorPreference: publisherExecutor) {
            try await repository.publish(snapshot, for: request, refreshedAt: .now)
        }

        do {
            // The marker is adjacent to the writer await. The dedicated publisher
            // executor observes that job's suspension while the actual GRDB writer
            // queue remains held, proving the publication was queued before cancel.
            await publisherExecutor.waitUntilPublisherSuspendedAfterSubmission()
            publication.cancel()
            blocker.releaseWriterQueue()
            try await holder.value
            await #expect(throws: CancellationError.self) { try await publication.value }
        } catch {
            publication.cancel()
            blocker.releaseWriterQueue()
            holder.cancel()
            _ = try? await holder.value
            _ = try? await publication.value
            throw error
        }

        #expect(try await repository.hasPersistedSnapshots() == false)
        try await repository.finishRequest(request, failed: false)
        #expect(try await repository.beginRequest(itemID: "item", vaultID: "vault", shareID: "share", kind: .selection) != nil)
    }

    @Test func cancellationAfterCommitPreservesCommittedSnapshot() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("offline-repository-test".utf8))
        try database.upsertVaults([PassVault(id: "vault", name: "Vault", shareId: "share")])
        try database.upsertItems([offlineTestMetadata(id: "item", vaultID: "vault")])
        let gate = PublicationGate()
        let repository = OfflineSnapshotRepository(database: database, afterPublication: { await gate.wait() })
        let fixture = OfflineRepositoryFixture(database: database, repository: repository)
        _ = try await repository.setVaultSelected(true, vaultID: "vault")
        let request = try #require(try await repository.beginRequest(
            itemID: "item", vaultID: "vault", shareID: "share", kind: .selection
        ))
        let snapshot = try fixture.snapshot(for: request, password: "fake")
        let task = Task { try await repository.publish(snapshot, for: request, refreshedAt: .now) }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.open()

        #expect(try await task.value)
        #expect(try await repository.authorizedSnapshot(for: request.key) == snapshot.snapshot)
    }

    @Test func corruptCleanupCannotDeleteReplacement() async throws {
        let fixture = try OfflineRepositoryFixture(itemIDs: ["item"])
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        let first = try #require(try await fixture.repository.beginRequest(
            itemID: "item", vaultID: "vault", shareID: "share", kind: .selection
        ))
        let corrupt = try fixture.snapshot(for: first, password: "old")
        #expect(try await fixture.repository.publish(corrupt, for: first, refreshedAt: .now))
        let refresh = try #require(try await fixture.repository.beginRequest(
            itemID: "item", vaultID: "vault", shareID: "share", kind: .refresh
        ))
        let replacement = try fixture.snapshot(for: refresh, password: "new")
        #expect(try await fixture.repository.publish(replacement, for: refresh, refreshedAt: .now))

        try await fixture.repository.discardCorruptSnapshot(corrupt.snapshot)

        #expect(try await fixture.repository.authorizedSnapshot(for: refresh.key) == replacement.snapshot)
    }

    @Test func unsupportedVersionIsNotDeletedDuringCorruptionCleanup() async throws {
        let fixture = try OfflineRepositoryFixture(itemIDs: ["item"])
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        try OfflineCatalogFixtureSupport.selectManualItem(in: fixture.database, itemId: "item", vaultId: "vault")
        let unsupported = EncryptedOfflineSnapshot(
            identity: OfflineSnapshotIdentity(
                key: OfflineSnapshotKey(vaultId: "vault", itemId: "item", schemaVersion: 2),
                revision: UUID(),
                keyFingerprint: Data(repeating: 7, count: 32)
            ),
            payload: Data(repeating: 1, count: OfflineSnapshotLimits.ciphertextBytes)
        )
        try await fixture.database.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO offlineSnapshots
                (vaultId, itemId, schemaVersion, snapshotRevision, keyFingerprint, encryptedPayload)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: ["vault", "item", 2, unsupported.identity.revision.uuidString, unsupported.identity.keyFingerprint, unsupported.payload]
            )
        }

        await #expect(throws: OfflinePersistenceError.unsupportedSchemaVersion) {
            try await fixture.repository.discardCorruptSnapshot(unsupported)
        }
        #expect(try await fixture.repository.hasPersistedSnapshots())
    }

    @Test func statusUpdateFailureRollsBackPriorSnapshotWrite() async throws {
        let fixture = try OfflineRepositoryFixture(itemIDs: ["item"])
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        let initialRequest = try #require(try await fixture.repository.beginRequest(
            itemID: "item", vaultID: "vault", shareID: "share", kind: .selection
        ))
        let initialSnapshot = try fixture.snapshot(for: initialRequest, password: "old")
        let initialRefreshedAt = Date(timeIntervalSince1970: 10)
        #expect(try await fixture.repository.publish(
            initialSnapshot,
            for: initialRequest,
            refreshedAt: initialRefreshedAt
        ))
        let refresh = try #require(try await fixture.repository.beginRequest(
            itemID: "item", vaultID: "vault", shareID: "share", kind: .refresh
        ))
        let replacement = try fixture.snapshot(for: refresh, password: "new")
        try await fixture.database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER rejectOfflineSelectionStatus
                BEFORE UPDATE OF cacheStatus, lastRefreshedAt, pendingRequestId ON offlineItems
                BEGIN
                    SELECT RAISE(ABORT, 'test');
                END
                """)
        }

        await #expect(throws: OfflinePersistenceError.persistenceFailed) {
            _ = try await fixture.repository.publish(replacement, for: refresh, refreshedAt: .now)
        }

        #expect(try await fixture.repository.authorizedSnapshot(for: refresh.key) == initialSnapshot.snapshot)
        let selection = try #require(try fixture.database.offlineItemSelection(itemId: "item"))
        #expect(selection.cacheStatus == .cached)
        #expect(selection.lastRefreshedAt == initialRefreshedAt)
        #expect(try await fixture.pendingRequestID(itemID: "item") == refresh.id.uuidString)

        try await fixture.database.writer.write { db in
            try db.execute(sql: "DROP TRIGGER rejectOfflineSelectionStatus")
        }
        #expect(try await fixture.repository.publish(replacement, for: refresh, refreshedAt: .now))
        #expect(try await fixture.repository.authorizedSnapshot(for: refresh.key) == replacement.snapshot)
    }
}


extension OfflineSnapshotRepositoryTests {
    @Test func manualSelectionDoesNotRequireOrSelectItsVault() async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["item"])
        let generation = try await f.repository.selectItemManually(itemID: "item", vaultID: "vault", shareID: "share")
        let row = try #require(try await f.repository.offlineItemSelection(itemId: "item"))
        #expect(row.isManuallySelected)
        #expect(row.selectionGeneration == generation)
        #expect(try await f.repository.offlineVaultIds().isEmpty)
    }

    @Test func repeatedManualSelectionPreservesGenerationAndReselectionReplacesIt() async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["item"])
        let first = try await f.repository.selectItemManually(itemID: "item", vaultID: "vault", shareID: "share")
        let repeated = try await f.repository.selectItemManually(itemID: "item", vaultID: "vault", shareID: "share")
        let request = try #require(try await f.repository.beginRequest(itemID: "item", vaultID: "vault", shareID: "share", kind: .selection))
        #expect(first == repeated)
        #expect(request.selectionGeneration == repeated)
        try await f.repository.removeItem("item")
        let reselected = try await f.repository.selectItemManually(itemID: "item", vaultID: "vault", shareID: "share")
        #expect(reselected != first)
        #expect(try await f.repository.offlineItemSelection(itemId: "item")?.selectionGeneration == reselected)
    }

    @Test func vaultDeselectPreservesOnlyManualSelectionsAndSnapshots() async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["manual", "bulk"])
        let policy = try #require(try await f.repository.setVaultSelected(true, vaultID: "vault"))
        let bulk = try #require(try await f.repository.beginRequest(
            itemID: "bulk", vaultID: "vault", shareID: "share", kind: .vaultSelection(policyGeneration: policy.generation)
        ))
        #expect(try await f.repository.publish(try OfflineRepositoryFixture(database: f.database, repository: f.repository).snapshot(for: bulk, password: "bulk"), for: bulk, refreshedAt: .now))
        let generation = try await f.repository.selectItemManually(itemID: "manual", vaultID: "vault", shareID: "share")
        let manual = try #require(try await f.repository.beginRequest(itemID: "manual", vaultID: "vault", shareID: "share", kind: .selection))
        #expect(manual.selectionGeneration == generation)
        #expect(try await f.repository.publish(try OfflineRepositoryFixture(database: f.database, repository: f.repository).snapshot(for: manual, password: "manual"), for: manual, refreshedAt: .now))

        _ = try await f.repository.setVaultSelected(false, vaultID: "vault")

        #expect(try await f.repository.hasAuthorizedSnapshot(for: manual.key))
        #expect(try await f.repository.hasAuthorizedSnapshot(for: bulk.key) == false)
        #expect(try await f.repository.offlineItemSelection(itemId: "manual")?.isManuallySelected == true)
        #expect(try await f.repository.offlineItemSelection(itemId: "bulk") == nil)
    }

    @Test func promotionPreservesCiphertextStatusTimestampAndPendingRefreshAcrossVaultDeselect() async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["item"])
        let policy = try #require(try await f.repository.setVaultSelected(true, vaultID: "vault"))
        let request = try #require(try await f.repository.beginRequest(
            itemID: "item", vaultID: "vault", shareID: "share", kind: .vaultSelection(policyGeneration: policy.generation)
        ))
        let snapshot = try OfflineRepositoryFixture(database: f.database, repository: f.repository).snapshot(for: request, password: "fake")
        let refreshedAt = Date(timeIntervalSince1970: 30)
        #expect(try await f.repository.publish(snapshot, for: request, refreshedAt: refreshedAt))
        let refresh = try #require(try await f.repository.beginRequest(itemID: "item", vaultID: "vault", shareID: "share", kind: .refresh))
        let before = try #require(try await persistedSelectionState(database: f.database))
        try await f.repository.keepItemOfflineIndividually(itemID: "item", vaultID: "vault")
        _ = try await f.repository.setVaultSelected(false, vaultID: "vault")
        let after = try #require(try await persistedSelectionState(database: f.database))
        #expect(after.ciphertext == before.ciphertext)
        #expect(after.cacheStatus == before.cacheStatus)
        #expect(after.lastRefreshedAt == before.lastRefreshedAt)
        #expect(after.pendingRequestID == refresh.id.uuidString)
        #expect(after.isManuallySelected)
        #expect(try await f.repository.hasAuthorizedSnapshot(for: request.key))
        let fixture = OfflineRepositoryFixture(database: f.database, repository: f.repository)
        #expect(try await f.repository.publish(try fixture.snapshot(for: refresh, password: "refreshed"), for: refresh, refreshedAt: .now))
    }

    @Test func reservedVaultWorkCanPublishAfterPromotionAndVaultDeselect() async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["item"])
        let policy = try #require(try await f.repository.setVaultSelected(true, vaultID: "vault"))
        let token = try #require(try await f.repository.beginRequest(
            itemID: "item", vaultID: "vault", shareID: "share", kind: .vaultSelection(policyGeneration: policy.generation)
        ))
        try await f.repository.keepItemOfflineIndividually(itemID: "item", vaultID: "vault")
        _ = try await f.repository.setVaultSelected(false, vaultID: "vault")
        let fixture = OfflineRepositoryFixture(database: f.database, repository: f.repository)
        #expect(try await f.repository.publish(try fixture.snapshot(for: token, password: "promoted"), for: token, refreshedAt: .now))
        #expect(try await f.repository.hasAuthorizedSnapshot(for: token.key))
    }

    @Test func obsoleteMaterializationAndVaultPolicyGenerationsCannotReserve() async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["item"])
        let manualGeneration = try await f.repository.selectItemManually(itemID: "item", vaultID: "vault", shareID: "share")
        let metadata = try #require(f.items.first)
        let reserved = try #require(try await f.repository.beginRequest(
            itemID: "item", vaultID: "vault", shareID: "share", kind: .materialization,
            expectations: .init(selectionGeneration: manualGeneration, metadataModifyTime: metadata.modifyTime, itemType: metadata.itemType)
        ))
        #expect(reserved.selectionGeneration == manualGeneration)
        #expect(try await f.repository.beginRequest(
            itemID: "item", vaultID: "vault", shareID: "share", kind: .materialization,
            expectations: .init(selectionGeneration: manualGeneration, metadataModifyTime: metadata.modifyTime, itemType: metadata.itemType)
        ) == nil)
        try await f.repository.finishRequest(reserved, failed: false)
        _ = try await f.repository.setVaultSelected(true, vaultID: "vault")
        let oldPolicy = try #require(try await f.repository.setVaultSelected(true, vaultID: "vault"))
        _ = try await f.repository.setVaultSelected(false, vaultID: "vault")
        let currentPolicy = try #require(try await f.repository.setVaultSelected(true, vaultID: "vault"))
        #expect(currentPolicy.generation != oldPolicy.generation)
        #expect(try await f.repository.beginRequest(
            itemID: "item", vaultID: "vault", shareID: "share", kind: .vaultSelection(policyGeneration: oldPolicy.generation),
            expectations: .init(metadataModifyTime: metadata.modifyTime, itemType: metadata.itemType)
        ) == nil)
    }

    @Test func obsoleteMetadataCandidateCannotCreateSelectionOrRequestOwnership() async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["item"])
        let metadata = try #require(f.items.first)
        #expect(try await f.repository.beginRequest(
            itemID: "item", vaultID: "vault", shareID: "share", kind: .selection,
            expectations: .init(metadataModifyTime: metadata.modifyTime.addingTimeInterval(1), itemType: metadata.itemType)
        ) == nil)
        #expect(try await f.repository.offlineItemSelection(itemId: "item") == nil)
        let pending = try await f.database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT pendingRequestId FROM offlineItems WHERE itemId = 'item'")
        }
        #expect(pending == nil)
    }

    @Test func exclusionSurvivesVaultDeselectAndReselectUntilManualSelection() async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["item"])
        _ = try await f.repository.setVaultSelected(true, vaultID: "vault")
        try await f.repository.removeItem("item")
        _ = try await f.repository.setVaultSelected(false, vaultID: "vault")
        _ = try await f.repository.setVaultSelected(true, vaultID: "vault")

        let policy = try #require(try await f.repository.itemPolicy(itemID: "item", vaultID: "vault"))
        #expect(policy.isExcluded)
        #expect(try await f.repository.workCandidates(vaultID: "vault", includeNewSelections: true, refreshExisting: true).isEmpty)
    }

    @Test func selectedItemWorkCandidateIsScopedAndNeverExpandsVaultMembership() async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["target", "neighbor", "excluded"])
        _ = try await f.repository.selectItemManually(itemID: "target", vaultID: "vault", shareID: "share")
        _ = try await f.repository.setVaultSelected(true, vaultID: "vault")
        let candidate = try #require(try await f.repository.workCandidateForSelectedItem(itemID: "target", vaultID: "vault"))
        #expect(candidate.key.itemId == "target")
        if case .materialize = candidate.intent {} else { Issue.record("expected selected item materialization") }
        #expect(try await f.repository.workCandidateForSelectedItem(itemID: "neighbor", vaultID: "vault") == nil)
        try await f.repository.removeItem("excluded")
        #expect(try await f.repository.itemPolicy(itemID: "excluded", vaultID: "vault")?.isExcluded == true)
        #expect(try await f.repository.workCandidateForSelectedItem(itemID: "excluded", vaultID: "vault") == nil)
        try f.database.upsertVaults([PassVault(id: "other", name: "Other", shareId: "other-share")])
        let moved = offlineTestMetadata(id: "target", vaultID: "other")
        try f.database.upsertItems([moved])
        #expect(try await f.repository.workCandidateForSelectedItem(itemID: "target", vaultID: "vault") == nil)
        #expect(try await f.repository.workCandidateForSelectedItem(itemID: "target", vaultID: "other") == nil)
        try await f.repository.removeItem("target")
        #expect(try await f.repository.workCandidateForSelectedItem(itemID: "target", vaultID: "vault") == nil)
    }

    @Test func workCandidatesRespectNewSelectionAndRefreshSwitches() async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["manual", "bulk"])
        _ = try await f.repository.selectItemManually(itemID: "manual", vaultID: "vault", shareID: "share")
        let manualOnly = try await f.repository.workCandidates(vaultID: nil, includeNewSelections: true, refreshExisting: false)
        #expect(manualOnly.map(\.key.itemId) == ["manual"])
        let manualGeneration = try #require(try await f.repository.offlineItemSelection(itemId: "manual")).selectionGeneration
        #expect(manualOnly.first?.intent == .materialize(selectionGeneration: manualGeneration))
        #expect(try await f.repository.workCandidates(vaultID: nil, includeNewSelections: false, refreshExisting: false).isEmpty)
        #expect(try await f.repository.workCandidates(vaultID: nil, includeNewSelections: false, refreshExisting: true).isEmpty)

        let policy = try #require(try await f.repository.setVaultSelected(true, vaultID: "vault"))
        let beforeCopies = try await f.repository.workCandidates(vaultID: "vault", includeNewSelections: true, refreshExisting: false)
        #expect(beforeCopies.map(\.key.itemId) == ["bulk", "manual"])
        #expect(beforeCopies.first?.intent == .vaultMaterialize(policyGeneration: policy.generation))
        let bulkRequest = try #require(try await f.repository.beginRequest(
            itemID: "bulk", vaultID: "vault", shareID: "share", kind: .vaultSelection(policyGeneration: policy.generation)
        ))
        let fixture = OfflineRepositoryFixture(database: f.database, repository: f.repository)
        #expect(try await f.repository.publish(try fixture.snapshot(for: bulkRequest, password: "bulk"), for: bulkRequest, refreshedAt: .now))
        let refreshes = try await f.repository.workCandidates(vaultID: "vault", includeNewSelections: false, refreshExisting: true)
        #expect(refreshes.map(\.key.itemId) == ["bulk"])
        #expect(refreshes.first?.intent == .refresh(selectionGeneration: bulkRequest.selectionGeneration))
        let newSelections = try await f.repository.workCandidates(vaultID: "vault", includeNewSelections: true, refreshExisting: false)
        #expect(newSelections.map(\.key.itemId) == ["manual"])
        #expect(try await f.repository.workCandidates(vaultID: "vault", includeNewSelections: false, refreshExisting: false).isEmpty)
    }

    @Test func removeUnderVaultPolicyPersistsExclusionUntilExplicitReselection() async throws {
        let f = try OfflineLifecycleFixture(itemIDs: ["item"])
        _ = try await f.repository.setVaultSelected(true, vaultID: "vault")
        try await f.repository.removeItem("item")
        let excludedPolicy = try #require(try await f.repository.itemPolicy(itemID: "item", vaultID: "vault"))
        #expect(excludedPolicy.isExcluded)
        #expect(try await f.repository.workCandidates(vaultID: "vault", includeNewSelections: true, refreshExisting: false).isEmpty)
        _ = try await f.repository.selectItemManually(itemID: "item", vaultID: "vault", shareID: "share")
        let manualPolicy = try #require(try await f.repository.itemPolicy(itemID: "item", vaultID: "vault"))
        #expect(manualPolicy.isManuallySelected)
        #expect(!manualPolicy.isExcluded)
    }

    @Test(arguments: ["revision", "schemaVersion", "shortCiphertext"])
    func recoveryMarksStructurallyUnusableSnapshotsUnavailableWithoutDeletingBytes(_ corruption: String) async throws {
        let fixture = try OfflineRepositoryFixture(itemIDs: ["item"])
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        let request = try #require(try await fixture.repository.beginRequest(
            itemID: "item", vaultID: "vault", shareID: "share", kind: .selection
        ))
        let refreshedAt = Date(timeIntervalSince1970: 44)
        #expect(try await fixture.repository.publish(try fixture.snapshot(for: request, password: "cached"), for: request, refreshedAt: refreshedAt))
        try await fixture.database.writer.write { db in
            if corruption == "revision" {
                try db.execute(sql: "UPDATE offlineSnapshots SET snapshotRevision = 'unusable-revision' WHERE itemId = 'item'")
            } else if corruption == "schemaVersion" {
                try db.execute(sql: "UPDATE offlineSnapshots SET schemaVersion = 2 WHERE itemId = 'item'")
            } else {
                try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
                try db.execute(
                    sql: "UPDATE offlineSnapshots SET encryptedPayload = ? WHERE itemId = 'item'",
                    arguments: [Data(repeating: 1, count: 27)]
                )
                try db.execute(sql: "PRAGMA ignore_check_constraints = OFF")
            }
            try db.execute(sql: "UPDATE offlineItems SET pendingRequestId = 'abandoned-request' WHERE itemId = 'item'")
        }
        let before = try #require(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item"))

        try await fixture.repository.recoverAbandonedRequests()

        let after = try #require(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item"))
        #expect(after.schemaVersion == before.schemaVersion)
        #expect(after.revision == before.revision)
        #expect(after.fingerprint == before.fingerprint)
        #expect(after.payload == before.payload)
        #expect(after.selection.isManuallySelected)
        #expect(after.selection.selectionGeneration == request.selectionGeneration)
        #expect(after.selection.cacheStatus == .unavailable)
        #expect(after.selection.lastRefreshedAt == refreshedAt)
        #expect(after.pendingRequestID == nil)
        #expect(try await fixture.repository.hasAuthorizedSnapshot(for: request.key) == false)
    }

    @Test func publicationGateRejectsRevokedOrChangedVaultSelection() async throws {
        for revocation in ["remove", "deselect", "purge", "share", "inactive", "moved"] {
            let database = try DatabaseManager(inMemory: true, passphrase: Data("revocation-test".utf8))
            try database.upsertVaults([PassVault(id: "vault", name: "Vault", shareId: "share")])
            try database.upsertItems([offlineTestMetadata(id: "item", vaultID: "vault")])
            let gate = OfflineTestGate()
            let repository = OfflineSnapshotRepository(database: database, beforePublication: { try? await gate.wait() })
            let fixture = OfflineRepositoryFixture(database: database, repository: repository)
            let policy = try #require(try await repository.setVaultSelected(true, vaultID: "vault"))
            let request = try #require(try await repository.beginRequest(
                itemID: "item", vaultID: "vault", shareID: "share", kind: .vaultSelection(policyGeneration: policy.generation)
            ))
            let snapshot = try fixture.snapshot(for: request, password: "test")
            let publication = Task { try await repository.publish(snapshot, for: request, refreshedAt: .now) }
            try await gate.waitUntilEntered()
            switch revocation {
            case "remove": try await repository.removeItem("item")
            case "deselect": _ = try await repository.setVaultSelected(false, vaultID: "vault")
            case "purge": try await repository.purge()
            case "share": try database.upsertVaults([PassVault(id: "vault", name: "Vault", shareId: "changed")])
            case "inactive":
                let item = PassItem(
                    id: "item", vaultId: "vault", title: "Offline example", itemType: .login,
                    subtitle: "person@example.test", url: nil, hasTOTP: false, state: "Trashed",
                    createTime: Date(timeIntervalSince1970: 1), modifyTime: Date(timeIntervalSince1970: 3),
                    useCount: 0, lastUsedAt: nil
                )
                _ = try database.syncMetadata(vaults: [PassVault(id: "vault", name: "Vault", shareId: "share")], items: [item], descriptors: [])
            case "moved":
                let moved = offlineTestMetadata(id: "item", vaultID: "other")
                _ = try database.syncMetadata(
                    vaults: [PassVault(id: "vault", name: "Vault", shareId: "share"), PassVault(id: "other", name: "Other", shareId: "other-share")],
                    items: [moved], descriptors: []
                )
            default: Issue.record("Unexpected revocation case")
            }
            await gate.open()
            #expect(try await publication.value == false, "obsolete \(revocation) publication must be rejected")
            #expect(try await repository.hasPersistedSnapshots() == false)
        }
    }
}

private nonisolated struct PersistedOfflineCiphertext: Sendable, Equatable {
    let schemaVersion: Int
    let revision: String
    let fingerprint: Data
    let payload: Data
}

private nonisolated struct PersistedOfflineSelectionState: Sendable {
    let ciphertext: PersistedOfflineCiphertext
    let cacheStatus: String
    let lastRefreshedAt: Date?
    let pendingRequestID: String?
    let isManuallySelected: Bool
}

private func persistedSelectionState(database: DatabaseManager) async throws -> PersistedOfflineSelectionState? {
    try await database.reader.read { db in
        guard let row = try Row.fetchOne(db, sql: """
            SELECT s.schemaVersion, s.snapshotRevision, s.keyFingerprint, s.encryptedPayload,
                   o.cacheStatus, o.lastRefreshedAt, o.pendingRequestId, o.isManuallySelected
            FROM offlineSnapshots s JOIN offlineItems o ON o.itemId = s.itemId AND o.vaultId = s.vaultId
            WHERE s.itemId = 'item'
            """) else { return nil }
        return PersistedOfflineSelectionState(
            ciphertext: PersistedOfflineCiphertext(
                schemaVersion: row["schemaVersion"], revision: row["snapshotRevision"],
                fingerprint: row["keyFingerprint"], payload: row["encryptedPayload"]
            ),
            cacheStatus: row["cacheStatus"],
            lastRefreshedAt: row["lastRefreshedAt"],
            pendingRequestID: row["pendingRequestId"],
            isManuallySelected: (row["isManuallySelected"] as Int) == 1
        )
    }
}

private struct OfflineRepositoryFixture {
    let database: DatabaseManager
    let repository: OfflineSnapshotRepository
    let keyData = Data(repeating: 7, count: 32)

    init(itemIDs: [String]) throws {
        database = try DatabaseManager(inMemory: true, passphrase: Data("offline-repository-test".utf8))
        try database.upsertVaults([PassVault(id: "vault", name: "Vault", shareId: "share")])
        try database.upsertItems(itemIDs.map { offlineTestMetadata(id: $0, vaultID: "vault") })
        repository = OfflineSnapshotRepository(database: database)
    }

    init(database: DatabaseManager, repository: OfflineSnapshotRepository) {
        self.database = database
        self.repository = repository
    }

    func pendingRequestID(itemID: String) async throws -> String? {
        try await database.reader.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT pendingRequestId FROM offlineItems WHERE itemId = ?",
                arguments: [itemID]
            )
        }
    }

    func snapshot(for request: OfflineRequestToken, password: String) throws -> PreparedOfflineSnapshot {
        let cipher = try OfflineSnapshotCipher(keyData: keyData)
        let identity = OfflineSnapshotIdentity(
            key: request.key,
            revision: UUID(),
            keyFingerprint: cipher.fingerprint
        )
        let item = try offlineTestCLIItem(
            id: request.key.itemId,
            vaultID: request.key.vaultId,
            shareID: request.shareID,
            password: password
        )
        return PreparedOfflineSnapshot(
            snapshot: EncryptedOfflineSnapshot(identity: identity, payload: try cipher.seal(JSONEncoder().encode(item), for: identity)),
            sourceModifyTime: OfflineSourceModificationTime.parse(item.modifyTime)
        )
    }
}

private actor PublicationGate {
    private var entered = false
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private final class PublicationSubmissionMarker: Sendable {
    private let submitted = Mutex(false)

    func markSubmitted() {
        submitted.withLock { $0 = true }
    }

    func wasSubmitted() -> Bool {
        submitted.withLock { $0 }
    }
}

/// Runs only publisher jobs on a dedicated Dispatch queue. Its callback is after
/// `runSynchronously` returns, which is after the publisher has suspended in GRDB.
private final class PublisherTaskExecutor: TaskExecutor, Sendable {
    private let queue = DispatchQueue(label: "OfflineSnapshotRepositoryTests.publisher")
    private let marker: PublicationSubmissionMarker
    private let publisherSuspended = DispatchSemaphore(value: 0)
    private let waitingQueue = DispatchQueue(label: "OfflineSnapshotRepositoryTests.publisher-waiter")

    init(marker: PublicationSubmissionMarker) {
        self.marker = marker
    }

    func enqueue(_ job: UnownedJob) {
        queue.async { [self, job] in
            job.runSynchronously(on: asUnownedTaskExecutor())
            if marker.wasSubmitted() {
                publisherSuspended.signal()
            }
        }
    }

    func asUnownedTaskExecutor() -> UnownedTaskExecutor {
        UnownedTaskExecutor(ordinary: self)
    }

    func waitUntilPublisherSuspendedAfterSubmission() async {
        await withCheckedContinuation { continuation in
            waitingQueue.async { [publisherSuspended] in
                publisherSuspended.wait()
                continuation.resume()
            }
        }
    }
}

/// Blocks only the serialized GRDB writer queue; waiting happens on a separate test queue.
private final class WriterQueueBlocker: Sendable {
    private let writerHeld = DispatchSemaphore(value: 0)
    private let releaseWriter = DispatchSemaphore(value: 0)
    private let waitingQueue = DispatchQueue(label: "OfflineSnapshotRepositoryTests.writer-waiter")

    func holdWriterQueue() {
        writerHeld.signal()
        releaseWriter.wait()
    }

    func waitUntilWriterQueueIsHeld() async {
        await withCheckedContinuation { continuation in
            waitingQueue.async { [writerHeld] in
                writerHeld.wait()
                continuation.resume()
            }
        }
    }

    func releaseWriterQueue() {
        releaseWriter.signal()
    }
}

// swiftlint:enable file_length
