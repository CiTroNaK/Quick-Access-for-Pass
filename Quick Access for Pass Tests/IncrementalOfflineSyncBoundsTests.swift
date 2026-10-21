import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("Incremental sync consumer bounds", .timeLimit(.minutes(1)))
struct IncrementalOfflineSyncBoundsTests {
    @Test(arguments: [1, 40, 1300]) func fallbackRecheckNarrowsMetadataToOriginalProof(catalogSize: Int) async throws {
        let ids = (0..<catalogSize).map { String(format: "item-%03d", $0) }
        let (fixture, _) = try makeFixture(ids)
        try await fixture.initialize()
        try await fixture.select([ids[0]])
        let operation = fixture.database.beginSyncOperation()
        let capture = try #require(await fixture.service.captureForSync(operation: operation))
        let result = try fixture.result(ids.map { try incrementalSyncCLIItem(id: $0) }, provenance: .unavailable)
        let metadata = try await fixture.commit(result, operation: operation)
        let key = OfflineSnapshotKey(vaultId: "vault", itemId: ids[0], schemaVersion: OfflineSnapshotLimits.schemaVersion)
        let proof = try #require(metadata.offlineMetadataProofs[key])
        let counter = MetadataWriteCounter()
        try counter.install(on: fixture.database)
        let work = try await fixture.repository.syncWork(capture: capture, metadataProofs: [key: proof],
                                                        sourceTimes: [ids[0]: Date(timeIntervalSince1970: 2)], allowMembershipExpansion: false)
        let report = try counter.finish(on: fixture.database)
        #expect(work.count == 1)
        let narrowed = report.selectShapes.filter { $0.key.hasPrefix("SELECT I.*,") && $0.key.contains("AND I.ID IN (?)") }
        #expect(narrowed.values.reduce(0, +) == 1, "A per-copy fallback recheck must not project the whole unrelated catalog.")
        #expect(await fixture.codec.counts().prepared == 0)
        await fixture.service.finishSyncCapture(capture)
    }

    @Test func flushesAtThirtyTwoWithoutParallelPreparation() async throws {
        let ids = (0..<65).map { String(format: "item-%03d", $0) }
        let (fixture, repository) = try makeFixture(ids)
        try await fixture.initialize()
        try await fixture.select()
        try await fixture.sync(ids.map { try incrementalSyncCLIItem(id: $0) })
        #expect(await repository.batchCounts() == [32, 32, 1])
        #expect(await repository.batchBytes().allSatisfy { $0 <= OfflineSyncPublicationLimits.ciphertextBytes })
        #expect(await fixture.codec.counts().prepared == 65)
        #expect(await fixture.codec.counts().peak == 1)
        #expect(await fixture.viewer.calls().isEmpty)
    }

    @Test func flushesBeforeEightMiBWithOneAdditionalPreparedResult() async throws {
        let ids = (0..<5).map { "large-\($0)" }
        let (fixture, repository) = try makeFixture(ids)
        try await fixture.initialize()
        try await fixture.select()
        let synthetic = String(repeating: "x", count: 3 * 1024 * 1024)
        try await fixture.sync(ids.map { try incrementalSyncCLIItem(id: $0, password: synthetic) })
        #expect(await repository.batchCounts() == [2, 2, 1])
        #expect(await repository.batchBytes().allSatisfy { $0 <= OfflineSyncPublicationLimits.ciphertextBytes })
        #expect(await fixture.codec.counts().prepared == 5)
        #expect(await fixture.codec.counts().peak == 1)
    }

    @Test func middleBatchFailurePreservesEarlierCommitAndContinuesLaterBatch() async throws {
        let ids = (0..<65).map { String(format: "item-%03d", $0) }
        let (fixture, repository) = try makeFixture(ids)
        try await fixture.initialize()
        try await fixture.select()
        try await fixture.database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER failMiddleBatch BEFORE INSERT ON offlineSnapshots WHEN NEW.itemId = 'item-032'
                BEGIN SELECT RAISE(ABORT, 'synthetic batch failure'); END
                """)
        }
        try await fixture.sync(ids.map { try incrementalSyncCLIItem(id: $0) })
        #expect(await repository.batchCounts() == [32, 32, 1])
        let states = try await fixture.repository.offlineItemSelections()
        #expect(states.filter { $0.cacheStatus == .cached }.count == 33)
        #expect(states.filter { $0.cacheStatus == .unavailable }.count == 32)
        #expect(try await fixture.snapshot("item-000") != nil)
        #expect(try await fixture.snapshot("item-032") == nil)
        #expect(try await fixture.snapshot("item-064") != nil)
        #expect(try fixture.database.allActiveItems().count == 65)
    }

    private func makeFixture(_ ids: [String]) throws -> (IncrementalOfflineSyncFixture, IncrementalSyncRepository) {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("synthetic-sync-bounds".utf8))
        let repository = IncrementalSyncRepository(base: OfflineSnapshotRepository(database: database))
        return (try IncrementalOfflineSyncFixture(itemIDs: ids, database: database, persisting: repository), repository)
    }
}
