import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("Incremental ordinary sync reuse", .timeLimit(.minutes(1)))
struct IncrementalOfflineSyncTests {
    @Test func listPayloadPublishesWithoutViewAndEqualSyncDoesNotWriteAgain() async throws {
        let fixture = try IncrementalOfflineSyncFixture(itemIDs: ["item", "unselected"])
        try await fixture.initialize()
        try await fixture.select(["item"])
        let item = try incrementalSyncCLIItem(note: "list-only-synthetic")
        let unselected = try incrementalSyncCLIItem(id: "unselected")
        try await fixture.sync([item, unselected])
        let before = try #require(try await fixture.snapshot())
        let decoded = try await fixture.codec.decodeSnapshot(before)
        #expect(decoded.content.note == "list-only-synthetic")
        #expect(await fixture.viewer.calls().isEmpty)
        #expect(try await fixture.snapshot("unselected") == nil)
        let counter = MetadataWriteCounter()
        try counter.install(on: fixture.database)
        try await fixture.sync([item, unselected])
        let report = try counter.finish(on: fixture.database)
        #expect(report.updates.values.reduce(0, +) == 0)
        #expect(try await fixture.snapshot() == before)
        #expect(await fixture.codec.counts().prepared == 1)
        #expect(try await fixture.database.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM offlineSyncCaptures") } == 0)
    }

    @Test func exactlyOneChangedItemRefreshesAndPreparationStaysSequential() async throws {
        let fixture = try IncrementalOfflineSyncFixture(itemIDs: ["item", "neighbor"])
        try await fixture.initialize()
        try await fixture.select()
        let original = try incrementalSyncCLIItem()
        let neighbor = try incrementalSyncCLIItem(id: "neighbor")
        try await fixture.sync([original, neighbor])
        let before = try #require(try await fixture.snapshot("neighbor"))
        let count = await fixture.codec.counts().prepared
        let changed = try incrementalSyncCLIItem(password: "changed-synthetic", modifyTime: "1970-01-01T00:00:03Z")
        try await fixture.sync([changed, neighbor])
        #expect(try await fixture.snapshot("neighbor") == before)
        #expect(try await fixture.baseline() == Date(timeIntervalSince1970: 3))
        #expect(await fixture.codec.counts().prepared == count + 1)
        #expect(await fixture.codec.counts().peak == 1)
        #expect(await fixture.viewer.calls().isEmpty)
    }

    @Test func unavailableProvenanceFetchesOnlyNeededSelectedCopies() async throws {
        let fixture = try IncrementalOfflineSyncFixture(itemIDs: ["item", "neighbor", "unselected"])
        try await fixture.initialize()
        try await fixture.select(["item", "neighbor"])
        let first = try incrementalSyncCLIItem()
        let neighbor = try incrementalSyncCLIItem(id: "neighbor")
        let unselected = try incrementalSyncCLIItem(id: "unselected")
        try await fixture.sync([first, neighbor, unselected])
        _ = try #require(try await fixture.snapshot())
        let changed = try incrementalSyncCLIItem(modifyTime: "1970-01-01T00:00:03Z")
        await fixture.viewer.setItems([changed, neighbor, unselected])
        try await fixture.sync([changed, neighbor, unselected], provenance: .unavailable)
        #expect(await fixture.viewer.calls() == ["item"])
        try await fixture.sync([changed, neighbor, unselected], provenance: .unavailable)
        #expect(await fixture.viewer.calls() == ["item"])
        #expect(try await fixture.snapshot("unselected") == nil)
    }

    @Test func liveFallbackStoresActualPayloadTimeRatherThanListTime() async throws {
        let fixture = try IncrementalOfflineSyncFixture()
        try await fixture.initialize()
        try await fixture.select()
        let listed = try incrementalSyncCLIItem()
        let live = try incrementalSyncCLIItem(note: "live-only-synthetic", modifyTime: "1970-01-01T00:00:03Z")
        await fixture.viewer.setItems([live])
        try await fixture.sync([listed], provenance: .unavailable)
        #expect(await fixture.viewer.calls() == ["item"])
        #expect(try await fixture.baseline() == Date(timeIntervalSince1970: 3))
        let snapshot = try #require(try await fixture.snapshot())
        #expect(try await fixture.codec.decodeSnapshot(snapshot).content.note == "live-only-synthetic")
    }

    @Test func explicitRetryThenMatchingOrdinarySyncAddsZeroViews() async throws {
        let fixture = try IncrementalOfflineSyncFixture(itemIDs: ["item", "neighbor"])
        try await fixture.initialize()
        try await fixture.select()
        let item = try incrementalSyncCLIItem()
        let neighbor = try incrementalSyncCLIItem(id: "neighbor")
        try await fixture.sync([item, neighbor])
        _ = try #require(try await fixture.snapshot())
        await fixture.viewer.setItems([item, neighbor])
        #expect(try await fixture.service.retryOfflineItem(itemID: "item", vaultID: "vault") == .submitted)
        await fixture.service.waitUntilIdle()
        #expect(await fixture.viewer.calls() == ["item"])
        let retried = try #require(try await fixture.snapshot())
        try await fixture.sync([item, neighbor])
        #expect(await fixture.viewer.calls() == ["item"])
        #expect(try await fixture.snapshot() == retried)
    }

    @Test func oversizedItemBetweenHealthyNeighborsReportsOnlyThatFailure() async throws {
        let fixture = try IncrementalOfflineSyncFixture(itemIDs: ["a", "b", "c"])
        try await fixture.initialize()
        try await fixture.select()
        let items = try [incrementalSyncCLIItem(id: "a"),
                         incrementalSyncCLIItem(id: "b", password: String(repeating: "z", count: OfflineSnapshotLimits.plaintextBytes + 1)),
                         incrementalSyncCLIItem(id: "c")]
        try await fixture.sync(items)
        #expect(try await fixture.repository.offlineItemSelection(itemId: "a")?.cacheStatus == .cached)
        #expect(try await fixture.repository.offlineItemSelection(itemId: "b")?.cacheStatus == .unavailable)
        #expect(try await fixture.repository.offlineItemSelection(itemId: "c")?.cacheStatus == .cached)
        #expect(try await fixture.snapshot("b") == nil)
        #expect(await fixture.viewer.calls().isEmpty)
    }

    @Test(arguments: [false, true]) func unavailableReadinessStillCommitsOrdinaryMetadata(initialize: Bool) async throws {
        let fixture = try IncrementalOfflineSyncFixture()
        if initialize { try await fixture.service.initialize() } // Observation remains unproven.
        try await fixture.select()
        let item = try incrementalSyncCLIItem(title: "Ordinary metadata still succeeds")
        try await fixture.sync([item])
        #expect(try fixture.database.allActiveItems().first?.title == item.content.title)
        #expect(try await fixture.snapshot() == nil)
        #expect(await fixture.codec.counts().prepared == 0)
    }

    @Test func rejectedPreparedEnvelopeFinishesOnlyItsStillOwnedFailure() async throws {
        let fixture = try IncrementalOfflineSyncFixture()
        try await fixture.initialize()
        try await fixture.select()
        await fixture.codec.setMissingMarkers(["item"])
        try await fixture.sync([incrementalSyncCLIItem()])
        #expect(try await fixture.snapshot() == nil)
        #expect(try await fixture.repository.offlineItemSelection(itemId: "item")?.cacheStatus == .unavailable)
        #expect(await fixture.viewer.calls().isEmpty)
    }

    @Test func zeroSelectionsStillSynchronizesMetadataWithoutOpeningSnapshotKeys() async throws {
        let fixture = try IncrementalOfflineSyncFixture()
        try await fixture.initialize()
        try await fixture.sync([incrementalSyncCLIItem(title: "Metadata only")])
        #expect(try fixture.database.allActiveItems().first?.title == "Metadata only")
        #expect(try await fixture.snapshot() == nil)
        #expect(await fixture.codec.counts().prepared == 0)
        #expect(await fixture.viewer.calls().isEmpty)
    }
}
