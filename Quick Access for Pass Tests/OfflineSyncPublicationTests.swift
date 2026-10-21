import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("Conditional sync ciphertext publication", .timeLimit(.minutes(1)))
struct OfflineSyncPublicationTests {
    @Test func publishesThirtyTwoWithoutObservedReservationsAndSkipsNextUnchangedSync() async throws {
        let fixture = try OfflineSyncPublicationFixture(itemIDs: (0..<32).map { "item-\($0)" })
        try await fixture.selectAll()
        let capture = try await fixture.planning.capture()
        let work = try await fixture.work(capture)
        let publications = try await fixture.prepare(work)
        let committed = try await fixture.repository.publishSyncBatch(publications, capture: capture)
        #expect(committed == Set(work.map(\.key)))
        #expect(try await fixture.planning.scalar("SELECT COUNT(*) FROM offlineItems WHERE pendingRequestId IS NOT NULL") == 0)
        #expect(try await fixture.planning.scalar("SELECT COUNT(*) FROM offlineItems WHERE cacheStatus = 'cached'") == 32)
        #expect(try await fixture.planning.scalar("SELECT COUNT(*) FROM offlineSnapshots WHERE metadataGeneration IS NOT NULL") == 32)
        for candidate in work {
            let selection = try #require(try await fixture.repository.offlineItemSelection(itemId: candidate.key.itemId))
            #expect(selection.lastRefreshedAt == Date(timeIntervalSince1970: 41))
            #expect(try await fixture.baseline(candidate.key.itemId) == Date(timeIntervalSince1970: 2))
        }
        let next = try await fixture.planning.capture()
        #expect(try await fixture.work(next).isEmpty)
    }

    @Test func exactlyEightMiBOfRealCiphertextFitsOneBatch() async throws {
        let fixture = try OfflineSyncPublicationFixture()
        try await fixture.selectAll()
        let capture = try await fixture.planning.capture()
        let work = try await fixture.work(capture)
        let repository = fixture.repository
        let codec = OfflineSnapshotCodec(keyMaterialProvider: OfflineFixtureKeys(),
                                         hasPersistedSnapshots: { try await repository.hasPersistedSnapshots() })
        var publications: [OfflineSyncPublication] = []
        for candidate in work {
            let empty = try offlineTestCLIItem(id: candidate.key.itemId, vaultID: "vault", shareID: "share", password: "",
                                              modifyTime: "1970-01-01T00:00:02Z")
            let padding = 4 * 1024 * 1024 - 28 - (try JSONEncoder().encode(empty).count)
            let item = try offlineTestCLIItem(id: candidate.key.itemId, vaultID: "vault", shareID: "share",
                                             password: String(repeating: "z", count: padding), modifyTime: "1970-01-01T00:00:02Z")
            let prepared = try await codec.prepareSnapshot(from: item, for: OfflineSnapshotPreparationIdentity(
                key: candidate.key, shareID: "share", itemType: .login
            ))
            #expect(prepared.snapshot.payload.count == 4 * 1024 * 1024)
            publications.append(OfflineSyncPublication(work: candidate, prepared: prepared, refreshedAt: Date(timeIntervalSince1970: 41)))
        }
        #expect(publications.reduce(0) { $0 + $1.prepared.snapshot.payload.count } == 8 * 1024 * 1024)
        #expect(try await fixture.repository.publishSyncBatch(publications, capture: capture) == Set(work.map(\.key)))
    }

    @Test(arguments: [false, true]) func enforcesHardBatchLimitsBeforeAnyPublication(byteLimit: Bool) async throws {
        let count = byteLimit ? 3 : 33
        let fixture = try OfflineSyncPublicationFixture(itemIDs: (0..<count).map { "item-\($0)" })
        try await fixture.selectAll()
        let capture = try await fixture.planning.capture()
        var publications = try await fixture.prepare(fixture.work(capture))
        if byteLimit {
            publications = publications.map { fixture.replace($0, payload: Data(repeating: 7, count: 3 * 1024 * 1024)) }
        }
        await #expect(throws: OfflinePersistenceError.payloadTooLarge) {
            try await fixture.repository.publishSyncBatch(publications, capture: capture)
        }
        #expect(try await fixture.planning.scalar("SELECT COUNT(*) FROM offlineSnapshots") == 0)
    }

    @Test(arguments: ["identity", "schema", "fingerprint", "epoch", "source", "payload", "short"])
    func invalidMemberDoesNotPreventUnrelatedValidPublication(kind: String) async throws {
        let fixture = try OfflineSyncPublicationFixture(itemIDs: ["anchor", "item", "other"])
        try await fixture.selectAll()
        try await fixture.planning.cache(itemID: "anchor")
        let capture = try await fixture.planning.capture()
        let publications = try await fixture.prepare(fixture.work(capture))
        let item = try #require(publications.first { $0.work.key.itemId == "item" })
        let other = try #require(publications.first { $0.work.key.itemId == "other" })
        let invalid: OfflineSyncPublication
        switch kind {
        case "identity": invalid = fixture.replace(item, key: other.work.key)
        case "schema": invalid = fixture.replace(item, key: .init(vaultId: "vault", itemId: "item", schemaVersion: 2))
        case "fingerprint": invalid = fixture.replace(item, fingerprint: Data(repeating: 8, count: 31))
        case "epoch": invalid = fixture.replace(item, fingerprint: Data(repeating: 8, count: 32))
        case "payload": invalid = fixture.replace(item, payload: Data(repeating: 0, count: OfflineSnapshotLimits.ciphertextBytes + 1))
        case "short": invalid = fixture.replace(item, payload: Data(repeating: 0, count: 27))
        default:
            invalid = OfflineSyncPublication(work: item.work, prepared: PreparedOfflineSnapshot(
                snapshot: item.prepared.snapshot, sourceModifyTime: Date(timeIntervalSince1970: 3)
            ), refreshedAt: item.refreshedAt)
        }
        #expect(try await fixture.repository.publishSyncBatch([invalid, other], capture: capture) == [other.work.key])
        #expect(try await fixture.repository.authorizedSnapshot(for: item.work.key) == nil)
    }

    @Test func materializesKnownAndFutureMembersAtomicallyWithoutPendingOwner() async throws {
        let fixture = try OfflineSyncPublicationFixture(itemIDs: ["known"])
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        let capture = try await fixture.planning.capture()
        let work = try await fixture.work(capture, incomingIDs: ["known", "future"])
        #expect(work.count == 2)
        for item in work {
            guard case .vaultMember(_, let known) = item.ownership else { Issue.record("Invented selected ownership"); continue }
            #expect(known == (item.key.itemId == "known"))
        }
        let publications = try await fixture.prepare(work)
        #expect(try await fixture.repository.publishSyncBatch(publications, capture: capture) == Set(work.map(\.key)))
        #expect(try await fixture.planning.scalar("SELECT COUNT(*) FROM offlineItems WHERE isManuallySelected = 0 AND pendingRequestId IS NULL AND cacheStatus = 'cached'") == 2)
        #expect(try await fixture.planning.scalar("""
            SELECT COUNT(*) FROM offlineSnapshots s JOIN offlineItems o ON o.itemId = s.itemId AND o.vaultId = s.vaultId
            WHERE s.metadataGeneration = o.metadataGeneration
            """) == 2)
        let next = try await fixture.planning.capture()
        #expect(try await fixture.work(next, incomingIDs: ["known", "future"]).isEmpty)
    }

    @Test func failureRetainsUsableCiphertextAndLastSuccessfulBaseline() async throws {
        let fixture = try OfflineSyncPublicationFixture(itemIDs: ["item"])
        try await fixture.planning.cache(sourceTime: "1970-01-01T00:00:01Z")
        let capture = try await fixture.planning.capture()
        let work = try await fixture.work(capture)
        let before = try #require(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item"))
        let keys = OfflineFixtureKeys(initialMaterial: nil)
        let repository = fixture.repository
        let codec = OfflineSnapshotCodec(keyMaterialProvider: keys, hasPersistedSnapshots: { try await repository.hasPersistedSnapshots() })
        let item = try offlineTestCLIItem(id: "item", vaultID: "vault", shareID: "share", password: "synthetic")
        await #expect(throws: OfflineSnapshotCodec.Error.keyUnavailable) {
            try await codec.prepareSnapshot(from: item, for: OfflineSnapshotPreparationIdentity(key: work[0].key, shareID: "share", itemType: .login))
        }
        #expect(await keys.createCount() == 0)
        try await fixture.repository.finishSyncFailures(work, capture: capture)
        let after = try #require(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item"))
        #expect(after.selection.cacheStatus == .failed)
        #expect(after.payload == before.payload)
        #expect(after.revision == before.revision)
        #expect(after.selection.lastRefreshedAt == before.selection.lastRefreshedAt)
        #expect(try await fixture.baseline() == Date(timeIntervalSince1970: 1))
        #expect(try await fixture.repository.hasAuthorizedSnapshot(for: work[0].key))
        let late = try await fixture.prepare(work)
        #expect(try await fixture.repository.publishSyncBatch(late, capture: capture).isEmpty)
    }
}
