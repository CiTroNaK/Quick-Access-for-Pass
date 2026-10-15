import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("Incremental sync lifecycle races", .timeLimit(.minutes(1)))
struct IncrementalOfflineSyncRaceTests {
    @Test(arguments: [false, true]) func removalOrPurgeCommitsWhileCodecIsHeld(purge: Bool) async throws {
        let fixture = try IncrementalOfflineSyncFixture(itemIDs: ["item", "other"])
        try await fixture.initialize()
        try await fixture.select()
        try await fixture.sync([incrementalSyncCLIItem(), incrementalSyncCLIItem(id: "other")])
        _ = try #require(try await fixture.snapshot())
        let operation = fixture.database.beginSyncOperation()
        let capture = try #require(await fixture.service.captureForSync(operation: operation))
        let result = try fixture.result([incrementalSyncCLIItem(modifyTime: "1970-01-01T00:00:03Z"),
                                         incrementalSyncCLIItem(id: "other", modifyTime: "1970-01-01T00:00:03Z")])
        let metadata = try await fixture.commit(result, operation: operation)
        let gate = IncrementalSyncGate()
        await fixture.codec.setGate(gate, itemIDs: ["item"])
        let task = Task { try await consume(fixture, result: result, metadata: metadata, capture: capture) }
        defer { task.cancel() }
        await gate.waitUntilEntered()
        if purge { try await fixture.service.removeAllOfflineData() }
        else { try await fixture.service.removeOfflineItem(itemId: "item") }
        #expect(try await fixture.repository.offlineItemSelection(itemId: "item") == nil)
        await gate.open()
        try await task.value
        #expect(try await fixture.snapshot() == nil)
        if purge { #expect(try await fixture.snapshot("other") == nil) }
        else { #expect(try await fixture.baseline("other") == Date(timeIntervalSince1970: 3)) }
    }

    @Test func stopRevokesCaptureBeforeJoiningHeldPreparation() async throws {
        let (fixture, repository) = try instrumentedFixture()
        try await fixture.initialize()
        try await fixture.select()
        try await fixture.sync([incrementalSyncCLIItem()])
        let before = try #require(try await fixture.snapshot())
        let operation = fixture.database.beginSyncOperation()
        let capture = try #require(await fixture.service.captureForSync(operation: operation))
        let result = try fixture.result([incrementalSyncCLIItem(modifyTime: "1970-01-01T00:00:03Z")])
        let metadata = try await fixture.commit(result, operation: operation)
        let gate = IncrementalSyncGate()
        await fixture.codec.setGate(gate)
        let task = Task { try await consume(fixture, result: result, metadata: metadata, capture: capture) }
        defer { task.cancel() }
        await gate.waitUntilEntered()
        let priorEnds = await repository.endCount()
        let stopped = IncrementalSyncSignal()
        let stop = Task { await fixture.service.stop(); stopped.mark() }
        await repository.waitForEnd(priorEnds + 1)
        #expect(try await captureCount(fixture.database) == 0)
        #expect(try await fixture.snapshot() == before)
        await gate.open()
        try await task.value
        await stop.value
        #expect(try await fixture.snapshot() == before)
    }

    @Test func stopRacingCaptureCreationCleansTheLateReturnedHandle() async throws {
        let admissionClosed = IncrementalSyncSignal()
        let (fixture, repository) = try instrumentedFixture(stopAdmissionMarker: { admissionClosed.mark() })
        try await fixture.initialize()
        try await fixture.select()
        let gate = IncrementalSyncGate()
        await repository.setCaptureGate(gate)
        let operation = fixture.database.beginSyncOperation()
        let creating = Task { await fixture.service.captureForSync(operation: operation) }
        await gate.waitUntilEntered()
        let stop = Task { await fixture.service.stop() }
        await admissionClosed.wait()
        await gate.open()
        #expect(await creating.value == nil)
        await stop.value
        #expect(try await captureCount(fixture.database) == 0)
        #expect(await fixture.viewer.calls().isEmpty)
    }

    @Test(arguments: [false, true]) func newerPendingOrCompletedRetryCannotBeAdoptedOrCleared(pending: Bool) async throws {
        let fixture = try IncrementalOfflineSyncFixture()
        try await fixture.initialize()
        try await fixture.select()
        try await fixture.sync([incrementalSyncCLIItem()])
        let operation = fixture.database.beginSyncOperation()
        let capture = try #require(await fixture.service.captureForSync(operation: operation))
        let listed = try incrementalSyncCLIItem(note: "older-list", modifyTime: "1970-01-01T00:00:03Z")
        let result = try fixture.result([listed])
        let metadata = try await fixture.commit(result, operation: operation)
        let preparation = IncrementalSyncGate()
        await fixture.codec.setGate(preparation)
        let old = Task { try await consume(fixture, result: result, metadata: metadata, capture: capture) }
        await preparation.waitUntilEntered()
        await fixture.codec.setGate(nil)
        let live = try incrementalSyncCLIItem(note: "newer-retry", modifyTime: "1970-01-01T00:00:03Z")
        await fixture.viewer.setItems([live])
        let view = IncrementalSyncGate()
        if pending { await fixture.viewer.setGate(view) }
        #expect(try await fixture.service.retryOfflineItem(itemID: "item", vaultID: "vault") == .submitted)
        if pending { await view.waitUntilEntered() }
        else { await fixture.service.waitUntilIdle() }
        let retryOwned = try #require(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item"))
        await preparation.open()
        try await old.value
        #expect(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item") == retryOwned)
        if pending { await view.open(); await fixture.service.waitUntilIdle() }
        let snapshot = try #require(try await fixture.snapshot())
        #expect(try await fixture.codec.decodeSnapshot(snapshot).content.note == "newer-retry")
        #expect(await fixture.viewer.calls() == ["item"])
    }

    @Test func captureFailureIsOptionalAndDoesNotFailMetadataSync() async throws {
        let (fixture, repository) = try instrumentedFixture()
        try await fixture.initialize()
        try await fixture.select()
        await repository.setCaptureFailure(true)
        let item = try incrementalSyncCLIItem(title: "Metadata committed without offline admission")
        try await fixture.sync([item])
        #expect(try fixture.database.allActiveItems().first?.title == item.content.title)
        #expect(try await fixture.snapshot() == nil)
        #expect(await fixture.viewer.calls().isEmpty)
        #expect(try await captureCount(fixture.database) == 0)
    }

    @Test(arguments: [false, true]) func sameTimeDirtyMetadataSurvivesFailureAndServiceRecreation(cancel: Bool) async throws {
        let fixture = try IncrementalOfflineSyncFixture()
        try await fixture.initialize()
        try await fixture.select()
        try await fixture.sync([incrementalSyncCLIItem(note: "old")])
        let before = try #require(try await fixture.snapshot())
        let operation = fixture.database.beginSyncOperation()
        let capture = try #require(await fixture.service.captureForSync(operation: operation))
        let changed = try incrementalSyncCLIItem(note: "updated", title: "Changed at equal source time")
        let result = try fixture.result([changed])
        let metadata = try await fixture.commit(result, operation: operation)
        if cancel {
            let gate = IncrementalSyncGate()
            await fixture.codec.setGate(gate)
            let task = Task { try await consume(fixture, result: result, metadata: metadata, capture: capture) }
            await gate.waitUntilEntered()
            task.cancel()
            await gate.open()
            await #expect(throws: CancellationError.self) { try await task.value }
        } else {
            await fixture.codec.setFailures(["item"])
            try await consume(fixture, result: result, metadata: metadata, capture: capture)
        }
        #expect(try await fixture.snapshot() == before)
        await fixture.service.stop()
        let recreated = try IncrementalOfflineSyncFixture(database: fixture.database, seedMetadata: false)
        try await recreated.initialize()
        let counter = MetadataWriteCounter()
        try counter.install(on: fixture.database)
        try await recreated.sync([changed])
        let report = try counter.finish(on: fixture.database)
        #expect(report.updates["items", default: 0] == 0)
        let refreshed = try #require(try await recreated.snapshot())
        #expect(refreshed.identity.revision != before.identity.revision)
        #expect(try await recreated.codec.decodeSnapshot(refreshed).content.note == "updated")
        #expect(try await recreated.baseline() == Date(timeIntervalSince1970: 2))
    }

    @Test func admittedOperationSurvivesObservationFailureButNewCaptureDoesNot() async throws {
        let fixture = try IncrementalOfflineSyncFixture()
        try await fixture.initialize()
        try await fixture.select()
        let operation = fixture.database.beginSyncOperation()
        let capture = try #require(await fixture.service.captureForSync(operation: operation))
        let result = try fixture.result([incrementalSyncCLIItem()])
        let metadata = try await fixture.commit(result, operation: operation)
        await fixture.service.updateSelectionObservation(generation: offlineFixtureObservationGeneration, status: .failed)
        try await consume(fixture, result: result, metadata: metadata, capture: capture)
        #expect(try await fixture.snapshot() != nil)
        #expect(await fixture.service.captureForSync(operation: fixture.database.beginSyncOperation()) == nil)
    }

    @Test func newerSyncAndOlderCleanupCannotOverwriteOrClearSuccessor() async throws {
        let fixture = try IncrementalOfflineSyncFixture()
        try await fixture.initialize()
        try await fixture.select()
        let first = fixture.database.beginSyncOperation()
        let old = try #require(await fixture.service.captureForSync(operation: first))
        let result = try fixture.result([incrementalSyncCLIItem()])
        let metadata = try await fixture.commit(result, operation: first)
        let gate = IncrementalSyncGate()
        await fixture.codec.setGate(gate)
        let oldTask = Task { try await consume(fixture, result: result, metadata: metadata, capture: old) }
        await gate.waitUntilEntered()
        await fixture.codec.setGate(nil)
        let next = fixture.database.beginSyncOperation()
        let current = try #require(await fixture.service.captureForSync(operation: next))
        let newerResult = try fixture.result([incrementalSyncCLIItem(modifyTime: "1970-01-01T00:00:03Z")])
        let newerMetadata = try await fixture.commit(newerResult, operation: next)
        try await fixture.service.consumeSyncResult(newerResult, capture: current, metadataProofs: newerMetadata.offlineMetadataProofs,
                                                   allowMembershipExpansion: true)
        await gate.open()
        await #expect(throws: CancellationError.self) { try await oldTask.value }
        await fixture.service.finishSyncCapture(old)
        #expect(try await captureCount(fixture.database) == 1)
        #expect(try await fixture.baseline() == Date(timeIntervalSince1970: 3))
        await fixture.service.finishSyncCapture(current)
        #expect(try await captureCount(fixture.database) == 0)
    }

    private func instrumentedFixture(stopAdmissionMarker: @escaping @Sendable () -> Void = {}) throws
        -> (IncrementalOfflineSyncFixture, IncrementalSyncRepository) {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("synthetic-sync-races".utf8))
        let repository = IncrementalSyncRepository(base: OfflineSnapshotRepository(database: database))
        return (try IncrementalOfflineSyncFixture(database: database, persisting: repository, stopAdmissionMarker: stopAdmissionMarker), repository)
    }
    private func captureCount(_ database: DatabaseManager) async throws -> Int {
        try await database.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM offlineSyncCaptures") ?? 0 }
    }
    private func consume(_ fixture: IncrementalOfflineSyncFixture, result: CLISyncFetchResult,
                         metadata: MetadataSynchronizationResult, capture: OfflineSyncCapture) async throws {
        do {
            try await fixture.service.consumeSyncResult(result, capture: capture, metadataProofs: metadata.offlineMetadataProofs,
                                                       allowMembershipExpansion: true)
            await fixture.service.finishSyncCapture(capture)
        } catch {
            await fixture.service.finishSyncCapture(capture)
            throw error
        }
    }
}
