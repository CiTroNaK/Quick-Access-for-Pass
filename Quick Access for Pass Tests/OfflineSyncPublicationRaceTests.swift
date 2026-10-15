import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("Sync publication ownership races", .timeLimit(.minutes(1)))
struct OfflineSyncPublicationRaceTests {
    @Test(arguments: ["metadata", "reselect", "pendingRetry", "completedRetry"])
    func staleMemberCannotStealOwnershipOrBlockAnotherMember(race: String) async throws {
        let fixture = try OfflineSyncPublicationFixture()
        try await fixture.selectAll()
        let capture = try await fixture.planning.capture()
        let work = try await fixture.work(capture)
        let publications = try await fixture.prepare(work)
        switch race {
        case "metadata":
            let item = incrementalMetadata(title: "Changed at the same source time")
            try fixture.database.upsertItems([item])
        case "reselect":
            try await fixture.repository.removeItem("item")
            _ = try await fixture.repository.selectItemManually(itemID: "item", vaultID: "vault", shareID: "share")
        case "pendingRetry":
            _ = try #require(try await fixture.repository.beginRequest(itemID: "item", vaultID: "vault", shareID: "share", kind: .selection))
        default: try await fixture.planning.cache(sourceTime: "1970-01-01T00:00:03Z")
        }
        let owned = try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item")
        let selection = try await fixture.repository.offlineItemSelection(itemId: "item")
        let requestGeneration = try await generations(fixture.database)["item"]
        let other = try #require(work.first { $0.key.itemId == "other" })
        #expect(try await fixture.repository.publishSyncBatch(publications, capture: capture) == [other.key])
        try await fixture.repository.finishSyncFailures(work, capture: capture)
        #expect(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item") == owned)
        #expect(try await fixture.repository.offlineItemSelection(itemId: "item") == selection)
        #expect(try await generations(fixture.database)["item"] == requestGeneration)
        if race == "pendingRetry" {
            #expect(try await fixture.planning.scalar("SELECT COUNT(*) FROM offlineItems WHERE itemId = 'item' AND pendingRequestId IS NOT NULL") == 1)
        }
        #expect(try await fixture.repository.offlineItemSelection(itemId: "other")?.cacheStatus == .cached)
    }

    @Test(arguments: ["manual", "exclusion", "policy", "ended", "operation"])
    func memberAdmissionIsRevalidatedInsteadOfInventingSelectedOwnership(race: String) async throws {
        let fixture = try OfflineSyncPublicationFixture()
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        let capture = try await fixture.planning.capture()
        let publications = try await fixture.prepare(fixture.work(capture))
        switch race {
        case "manual", "exclusion":
            _ = try await fixture.repository.selectItemManually(itemID: "item", vaultID: "vault", shareID: "share")
            if race == "exclusion" { try await fixture.repository.removeItem("item") }
        case "policy":
            _ = try await fixture.repository.setVaultSelected(false, vaultID: "vault")
            _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        case "ended": try await fixture.repository.endSyncCapture(capture)
        default: _ = fixture.database.beginSyncOperation()
        }
        let expected = Set(publications.filter { ["manual", "exclusion"].contains(race) && $0.work.key.itemId == "other" }.map { $0.work.key })
        #expect(try await fixture.repository.publishSyncBatch(publications, capture: capture) == expected)
        let itemKey = OfflineSnapshotKey(vaultId: "vault", itemId: "item", schemaVersion: 1)
        #expect(try await fixture.repository.authorizedSnapshot(for: itemKey) == nil)
    }

    @Test func rollbackDoesNotAdvanceAnyBaselineStatusOrRequestGeneration() async throws {
        let fixture = try OfflineSyncPublicationFixture()
        for id in fixture.itemIDs { try await fixture.planning.cache(itemID: id, sourceTime: "1970-01-01T00:00:01Z") }
        let capture = try await fixture.planning.capture()
        let publications = try await fixture.prepare(fixture.work(capture))
        let before = try await generations(fixture.database)
        try await fixture.database.writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER failSyncPublication BEFORE INSERT ON offlineSnapshots WHEN NEW.itemId = 'other'
                BEGIN SELECT RAISE(ABORT, 'synthetic rollback'); END
                """)
        }
        await #expect(throws: OfflinePersistenceError.persistenceFailed) {
            try await fixture.repository.publishSyncBatch(publications, capture: capture)
        }
        #expect(try await generations(fixture.database) == before)
        for id in fixture.itemIDs {
            #expect(try await fixture.baseline(id) == Date(timeIntervalSince1970: 1))
            #expect(try await fixture.repository.offlineItemSelection(itemId: id)?.lastRefreshedAt == Date(timeIntervalSince1970: 3))
        }
    }

    @Test func laterBatchFailureDoesNotUndoCommittedBatch() async throws {
        let fixture = try OfflineSyncPublicationFixture(itemIDs: (0..<32).map { "item-\($0)" } + ["last"])
        for id in fixture.itemIDs { try await fixture.planning.cache(itemID: id, sourceTime: "1970-01-01T00:00:01Z") }
        let capture = try await fixture.planning.capture()
        let publications = try await fixture.prepare(fixture.work(capture))
        let first = Array(publications.filter { $0.work.key.itemId != "last" })
        let last = try #require(publications.first { $0.work.key.itemId == "last" })
        #expect(try await fixture.repository.publishSyncBatch(first, capture: capture) == Set(first.map { $0.work.key }))
        try await fixture.database.writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER failLaterBatch BEFORE INSERT ON offlineSnapshots WHEN NEW.itemId = 'last'
                BEGIN SELECT RAISE(ABORT, 'synthetic later failure'); END
                """)
        }
        await #expect(throws: OfflinePersistenceError.persistenceFailed) {
            try await fixture.repository.publishSyncBatch([last], capture: capture)
        }
        try await fixture.repository.finishSyncFailures(first.map(\.work), capture: capture)
        try await fixture.repository.finishSyncFailures([last.work], capture: capture)
        for member in first {
            #expect(try await fixture.baseline(member.work.key.itemId) == Date(timeIntervalSince1970: 2))
            #expect(try await fixture.repository.offlineItemSelection(itemId: member.work.key.itemId)?.cacheStatus == .cached)
        }
        #expect(try await fixture.baseline("last") == Date(timeIntervalSince1970: 1))
        #expect(try await fixture.repository.offlineItemSelection(itemId: "last")?.cacheStatus == .failed)
    }

    @Test(arguments: [false, true]) func cancellationDistinguishesAdmissionFromAlreadyCommittedBatch(afterCommit: Bool) async throws {
        let fixture = try OfflineSyncPublicationFixture(itemIDs: ["item"])
        try await fixture.planning.cache(sourceTime: "1970-01-01T00:00:01Z")
        let capture = try await fixture.planning.capture()
        let publications = try await fixture.prepare(fixture.work(capture))
        let gate = OfflineTestGate()
        let repository = OfflineSnapshotRepository(database: fixture.database,
            beforePublication: { if !afterCommit { try? await gate.wait() } },
            afterPublication: { if afterCommit { try? await gate.wait() } })
        let task = Task { try await repository.publishSyncBatch(publications, capture: capture) }
        defer { task.cancel() }
        try await gate.waitUntilEntered()
        if afterCommit { _ = fixture.database.beginSyncOperation() }
        task.cancel()
        await gate.open()
        if afterCommit {
            #expect(try await task.value == Set(publications.map { $0.work.key }))
            #expect(try await fixture.baseline() == Date(timeIntervalSince1970: 2))
        } else {
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await fixture.baseline() == Date(timeIntervalSince1970: 1))
        }
    }

    @Test func waitingBatchDoesNotBlockRevocationOrCompletedRetry() async throws {
        let fixture = try OfflineSyncPublicationFixture()
        for id in fixture.itemIDs { try await fixture.planning.cache(itemID: id, sourceTime: "1970-01-01T00:00:01Z") }
        let capture = try await fixture.planning.capture()
        let publications = try await fixture.prepare(fixture.work(capture))
        let gate = OfflineTestGate()
        let repository = OfflineSnapshotRepository(database: fixture.database, beforePublication: { try? await gate.wait() })
        let task = Task { try await repository.publishSyncBatch(publications, capture: capture) }
        defer { task.cancel() }
        try await gate.waitUntilEntered()
        try await fixture.repository.removeItem("item")
        try await fixture.planning.cache(itemID: "other", sourceTime: "1970-01-01T00:00:03Z")
        await gate.open()
        #expect(try await task.value.isEmpty)
        #expect(try await fixture.repository.offlineItemSelection(itemId: "item") == nil)
        #expect(try await fixture.baseline("other") == Date(timeIntervalSince1970: 3))
    }

    @Test func cancelledPreparationLeavesCommittedCopyAndBaselineUntouched() async throws {
        let fixture = try OfflineSyncPublicationFixture(itemIDs: ["item"])
        try await fixture.planning.cache(sourceTime: "1970-01-01T00:00:01Z")
        let capture = try await fixture.planning.capture()
        let work = try await fixture.work(capture)
        let before = try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item")
        let generationsBefore = try await generations(fixture.database)
        let gate = OfflineTestGate()
        let repository = fixture.repository
        let codec = OfflineSnapshotCodec(keyMaterialProvider: OfflineSyncPreparationKeys(gate: gate),
                                         hasPersistedSnapshots: { try await repository.hasPersistedSnapshots() })
        let item = try offlineTestCLIItem(id: "item", vaultID: "vault", shareID: "share", password: "synthetic")
        let task = Task { try await codec.prepareSnapshot(from: item, for: OfflineSnapshotPreparationIdentity(
            key: work[0].key, shareID: "share", itemType: .login
        )) }
        defer { task.cancel() }
        try await gate.waitUntilEntered()
        task.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item") == before)
        #expect(try await generations(fixture.database) == generationsBefore)
        #expect(try await fixture.baseline() == Date(timeIntervalSince1970: 1))
    }

    @Test(arguments: [false, true]) func futureMemberCannotAdoptAnInterveningManualSelection(exclude: Bool) async throws {
        let fixture = try OfflineSyncPublicationFixture(itemIDs: ["known"])
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        let capture = try await fixture.planning.capture()
        let work = try await fixture.work(capture, incomingIDs: ["known", "future"])
        let publications = try await fixture.prepare(work)
        _ = try await fixture.repository.selectItemManually(itemID: "future", vaultID: "vault", shareID: "share")
        if exclude { try await fixture.repository.removeItem("future") }
        let known = try #require(work.first { $0.key.itemId == "known" })
        #expect(try await fixture.repository.publishSyncBatch(publications, capture: capture) == [known.key])
        #expect(try await fixture.planning.scalar("SELECT COUNT(*) FROM offlineSnapshots WHERE itemId = 'future'") == 0)
    }

    @Test func materializationRollbackLeavesNoInventedSelections() async throws {
        let fixture = try OfflineSyncPublicationFixture(itemIDs: ["first", "last"])
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        let capture = try await fixture.planning.capture()
        let publications = try await fixture.prepare(fixture.work(capture))
        try await fixture.database.writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER failMemberInsert BEFORE INSERT ON offlineSnapshots WHEN NEW.itemId = 'last'
                BEGIN SELECT RAISE(ABORT, 'synthetic member rollback'); END
                """)
        }
        await #expect(throws: OfflinePersistenceError.persistenceFailed) {
            try await fixture.repository.publishSyncBatch(publications, capture: capture)
        }
        #expect(try await fixture.planning.scalar("SELECT COUNT(*) FROM offlineItems") == 0)
        #expect(try await fixture.planning.scalar("SELECT COUNT(*) FROM offlineSnapshots") == 0)
        try await fixture.database.writer.write { try $0.execute(sql: "DROP TRIGGER failMemberInsert") }
        #expect(try await fixture.repository.publishSyncBatch(publications, capture: capture) == Set(publications.map { $0.work.key }))
    }

    @Test func futureFormatTargetIsNotImplicitlyRepaired() async throws {
        let fixture = try OfflineSyncPublicationFixture()
        for id in fixture.itemIDs { try await fixture.planning.cache(itemID: id, sourceTime: "1970-01-01T00:00:01Z") }
        let capture = try await fixture.planning.capture()
        let work = try await fixture.work(capture)
        let publications = try await fixture.prepare(work)
        try await fixture.database.writer.write {
            try $0.execute(sql: "UPDATE offlineSnapshots SET schemaVersion = 2 WHERE itemId = 'item'")
        }
        let other = try #require(work.first { $0.key.itemId == "other" })
        #expect(try await fixture.repository.publishSyncBatch(publications, capture: capture) == [other.key])
        #expect(try await fixture.planning.scalar("SELECT COUNT(*) FROM offlineSnapshots WHERE itemId = 'item' AND schemaVersion = 2") == 1)
    }

    private func generations(_ database: DatabaseManager) async throws -> [String: String] {
        try await database.reader.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT itemId, requestGeneration FROM offlineItems")
            return Dictionary(uniqueKeysWithValues: rows.map { (($0["itemId"] as String), ($0["requestGeneration"] as String)) })
        }
    }
}
