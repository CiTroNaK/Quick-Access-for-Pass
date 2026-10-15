import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("Offline request freshness", .timeLimit(.minutes(1)))
struct OfflineRequestFreshnessTests {
    @Test("completed explicit Retry retains a new durable request generation")
    func completedRetryAdvancesRequestGeneration() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let viewer = FreshnessViewer()
        let service = fixture.service(viewer: viewer)
        try await initializeOfflineFixtureService(service)
        try await service.makeAvailableOffline(item: fixture.items[0], shareId: "share")
        let before = try await ownership(in: fixture.database)
        #expect(before.pendingRequestID == nil)
        #expect(UUID(uuidString: before.metadataGeneration) != nil)
        #expect(UUID(uuidString: before.requestGeneration) != nil)

        let result = try await service.retryOfflineItem(itemID: "item", vaultID: "vault")
        #expect(result == .submitted)
        await service.waitUntilIdle()

        let after = try await ownership(in: fixture.database)
        #expect(after.pendingRequestID == nil)
        #expect(after.requestGeneration != before.requestGeneration)
        #expect(after.metadataGeneration == before.metadataGeneration)
        #expect(UUID(uuidString: after.requestGeneration) != nil)
        #expect(await viewer.callCount() == 2)
    }

    @Test("explicit preparation and publication record payload time, not catalog time")
    func explicitPublicationRecordsPayloadTime() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let service = fixture.service(viewer: FreshnessViewer())
        try await initializeOfflineFixtureService(service)
        try await service.makeAvailableOffline(item: fixture.items[0], shareId: "share")
        let state = try await ownership(in: fixture.database)
        let baseline = try await fixture.database.reader.read { db in
            try Row.fetchOne(db, sql: "SELECT sourceModifyTime, metadataGeneration FROM offlineSnapshots WHERE itemId = 'item'")
                .map { SnapshotBaseline(sourceTime: $0["sourceModifyTime"], metadataGeneration: $0["metadataGeneration"]) }
        }
        let published = try #require(baseline)
        let actualTime = try #require(OfflineSourceModificationTime.parse("2026-10-01T12:00:00Z"))
        #expect(published.sourceTime == actualTime)
        #expect(published.sourceTime != fixture.items[0].modifyTime)
        #expect(published.metadataGeneration == state.metadataGeneration)
    }

    @Test("a changed metadata generation rejects an otherwise matching explicit publication")
    func metadataGenerationChangeRejectsPublication() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let request = try #require(try await fixture.repository.beginRequest(
            itemID: "item", vaultID: "vault", shareID: "share", kind: .selection
        ))
        let item = try offlineTestCLIItem(id: "item", vaultID: "vault", shareID: "share", password: "synthetic")
        let prepared = try await fixture.codec().prepareSnapshot(from: item, for: request)
        // Test-target-only catalog mutation: production writers must use repository/database paths.
        try await fixture.database.writer.write { db in
            try db.execute(sql: "UPDATE offlineItems SET metadataGeneration = ? WHERE itemId = 'item'", arguments: [UUID().uuidString])
        }
        let published = try await fixture.repository.publish(prepared, for: request, refreshedAt: .now)
        #expect(!published)
        #expect(try await fixture.repository.hasPersistedSnapshots() == false)
    }

    @Test("stale completion leaves the newer pending owner and durable generation intact")
    func staleCompletionCannotClearNewOwner() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let older = try #require(try await fixture.repository.beginRequest(
            itemID: "item", vaultID: "vault", shareID: "share", kind: .selection
        ))
        let newer = try #require(try await fixture.repository.beginRequest(
            itemID: "item", vaultID: "vault", shareID: "share", kind: .selection
        ))
        let before = try await ownership(in: fixture.database)
        try await fixture.repository.finishRequest(older, failed: true)
        let after = try await ownership(in: fixture.database)
        #expect(after == before)
        #expect(after.pendingRequestID == newer.id.uuidString)
        try await fixture.repository.finishRequest(newer, failed: false)
        let completed = try await ownership(in: fixture.database)
        #expect(completed.pendingRequestID == nil)
        #expect(completed.requestGeneration == before.requestGeneration)
    }

    private func ownership(in database: DatabaseManager) async throws -> OwnershipState {
        try await database.reader.read { db in
            let row = try #require(try Row.fetchOne(db, sql: """
                SELECT metadataGeneration, requestGeneration, pendingRequestId FROM offlineItems WHERE itemId = 'item'
                """))
            return OwnershipState(metadataGeneration: row["metadataGeneration"], requestGeneration: row["requestGeneration"],
                                  pendingRequestID: row["pendingRequestId"])
        }
    }

    private struct OwnershipState: Sendable, Equatable {
        let metadataGeneration: String
        let requestGeneration: String
        let pendingRequestID: String?
    }

    private struct SnapshotBaseline: Sendable {
        let sourceTime: Date?
        let metadataGeneration: String?
    }
}

private actor FreshnessViewer: OfflineItemViewing {
    private var calls = 0
    func callCount() -> Int { calls }

    func viewItem(itemId: String, shareId: String) throws -> CLIItem {
        calls += 1
        return try offlineTestCLIItem(id: itemId, vaultID: "vault", shareID: shareId, password: "synthetic",
                                     modifyTime: "2026-10-01T12:00:00Z")
    }
}
