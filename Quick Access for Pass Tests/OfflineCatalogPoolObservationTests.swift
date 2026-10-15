import Foundation
import GRDB
import Synchronization
import Testing
@testable import Quick_Access_for_Pass

@Suite("Offline catalog pool observation")
struct OfflineCatalogPoolObservationTests {
    /// Changing offline selection must not run the full catalog SELECT on the writer.
    @Test(.timeLimit(.minutes(1)))
    func committedSelectionDoesNotRebuildCatalogOnWriter() async throws {
        let fixture = try OfflineCatalogPoolFixture()
        defer { fixture.remove() }
        var iterator = OfflineCatalogObservation(database: fixture.database).snapshots().makeAsyncIterator()
        let initial = try #require(try await iterator.next())
        #expect(initial.policyByItemID.isEmpty)
        let writerProjections = Mutex(0)
        try await fixture.database.writer.writeWithoutTransaction { db in
            db.trace { event in
                if case .statement(let statement) = event, statement.sql.contains("AS hasUsableSnapshot") {
                    writerProjections.withLock { $0 += 1 }
                }
            }
        }
        defer {
            fixture.database.writer.writeWithoutTransaction { db in db.trace(options: []) }
        }

        _ = try await fixture.repository.selectItemManually(itemID: "manual", vaultID: "vault", shareID: "share")
        let selected = try #require(try await iterator.next())
        #expect(selected.policyByItemID["manual"]?.isManuallySelected == true)
        #expect(writerProjections.withLock { $0 } == 0)
    }

    /// A stable observation region must include dependencies even when no selections exist yet.
    @Test(.timeLimit(.minutes(1)))
    func observesEveryCatalogDependencyStartingEmpty() async throws {
        let fixture = try OfflineCatalogPoolFixture()
        defer { fixture.remove() }
        var iterator = OfflineCatalogObservation(database: fixture.database).snapshots().makeAsyncIterator()
        let initial = try #require(try await iterator.next())
        #expect(initial.policyByItemID.isEmpty)

        _ = try await fixture.repository.selectItemManually(itemID: "manual", vaultID: "vault", shareID: "share")
        let selected = try await next(&iterator) { $0.policyByItemID["manual"] != nil }
        #expect(selected.vaults.first?.selectedCount == 1)
        _ = try await fixture.publish(itemID: "manual", kind: .materialization)
        let published = try await next(&iterator) { $0.vaults.first?.usableCount == 1 }
        #expect(published.availabilityByItemID["manual"] != .notCached)

        // Test-only corruption setup touches snapshots alone, not offlineItems.
        try await fixture.setSnapshotSchema(2)
        _ = try await next(&iterator) { $0.vaults.first?.usableCount == 0 }
        try await fixture.setSnapshotSchema(1)
        _ = try await next(&iterator) { $0.vaults.first?.usableCount == 1 }
        _ = try await fixture.publish(itemID: "manual", kind: .refresh, refreshedAt: Date(timeIntervalSince1970: 900))
        _ = try await next(&iterator) { $0.vaults.first?.lastRefreshedAt == Date(timeIntervalSince1970: 900) }

        try fixture.database.upsertVaults([PassVault(id: "vault", name: "Renamed vault", shareId: "share")])
        _ = try await next(&iterator) { $0.vaults.first?.vaultName == "Renamed vault" }
        try fixture.database.recordUsage(itemId: "manual")
        _ = try await next(&iterator) { $0.itemGroups.first?.items.first?.item.useCount == 1 }

        let policy = try #require(try await fixture.repository.setVaultSelected(true, vaultID: "vault"))
        _ = try await next(&iterator) { $0.selectedVaultIDs == ["vault"] }
        _ = try await fixture.publish(itemID: "vault-only", kind: .vaultSelection(policyGeneration: policy.generation))
        _ = try await next(&iterator) { $0.vaults.first?.usableCount == 2 }
        // Exclusion-only changes must hide and restore an otherwise retained vault-derived copy.
        try await fixture.setExclusion(true)
        _ = try await next(&iterator) { $0.policyByItemID["vault-only"] == nil }
        try await fixture.setExclusion(false)
        _ = try await next(&iterator) { $0.policyByItemID["vault-only"] != nil }
        try await fixture.repository.removeItem("vault-only")
        _ = try await next(&iterator) { $0.policyByItemID["vault-only"] == nil }
        _ = try await fixture.repository.setVaultSelected(false, vaultID: "vault")
        let deselected = try await next(&iterator) { $0.selectedVaultIDs.isEmpty }
        #expect(deselected.policyByItemID["manual"]?.isManuallySelected == true)
        try await fixture.repository.purge()
        let purged = try await next(&iterator) { $0.policyByItemID.isEmpty }
        #expect(purged.itemGroups.isEmpty)
        #expect(purged.vaults.first?.usableCount == 0)
    }

    private func next(
        _ iterator: inout AsyncThrowingStream<OfflinePresentationSnapshot, Error>.Iterator,
        matching predicate: (OfflinePresentationSnapshot) -> Bool
    ) async throws -> OfflinePresentationSnapshot {
        while let value = try await iterator.next(isolation: #isolation) {
            if predicate(value) { return value }
        }
        throw CancellationError()
    }
}

extension OfflineCatalogPoolObservationTests {
    @Test(.timeLimit(.minutes(3)))
    func thirteenHundredItemsBootstrapSkipAndChangeOnEncryptedPool() async throws {
        let pool = try OfflineCatalogPoolFixture(seedCatalog: false)
        defer { pool.remove() }
        #expect(pool.database.writer is DatabasePool)
        #expect(try await pool.database.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM grdb_migrations") } == 15)
        let handle = try FileHandle(forReadingFrom: pool.root.appendingPathComponent("catalog.db"))
        let header = try handle.read(upToCount: 16)
        try handle.close()
        #expect(header != Data("SQLite format 3\0".utf8))

        let ids = (0..<1300).map { "item-\($0)" }
        let repository = IncrementalSyncRepository(base: pool.repository)
        let keys = IncrementalPoolKeys()
        let fixture = try IncrementalOfflineSyncFixture(itemIDs: ids, database: pool.database, persisting: repository,
                                                       seedMetadata: false, keyMaterialProvider: keys)
        try pool.database.upsertVaults([PassVault(id: "vault", name: "Vault", shareId: "share")])
        _ = try await pool.repository.setVaultSelected(true, vaultID: "vault")
        try await fixture.initialize()
        let recorder = IncrementalPoolObservationRecorder()
        let observing = Task {
            do {
                for try await value in OfflineCatalogObservation(database: pool.database).snapshots() { await recorder.receive(value) }
            } catch { /* The terminal signal below also releases failed/cancelled waiters. */ }
            await recorder.finish()
        }
        defer { observing.cancel() }
        _ = try await recorder.wait { $0.selectedVaultIDs == ["vault"] && $0.policyByItemID.isEmpty }
        let probe = IncrementalPoolSQLProbe()
        try probe.install(on: pool.database)
        defer { probe.uninstall(from: pool.database) }
        // Negative controls prove actual execution/row-effect telemetry, including no-op UPDATEs.
        try await pool.database.writer.writeWithoutTransaction { db in
            _ = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items WHERE id = ?", arguments: ["missing"])
            try db.execute(sql: "UPDATE vaults SET name = name WHERE id = 'vault'")
        }
        let control = try probe.report(on: pool.database)
        #expect(control.pointItemLookups == 1)
        #expect(control.rowCount("vaults", "update") == 1)
        #expect(control.statements["vaults.update"] == 1)
        try probe.reset(on: pool.database)
        var items = try ids.map { try incrementalSyncCLIItem(id: $0, url: "https://scale.example.test") }
        let publicationGate = OfflineTestGate()
        await repository.setPublicationGate(publicationGate)
        let initialItems = items
        let cold = Task { try await fixture.sync(initialItems) }
        do {
            try await publicationGate.waitUntilEntered()
            #expect(await fixture.codec.counts().prepared == 33)
            #expect(await fixture.codec.counts().peak == 1)
            #expect(await repository.batchCounts() == [32])
            #expect(await repository.batchBytes().allSatisfy { $0 <= OfflineSyncPublicationLimits.ciphertextBytes })
            #expect(try await pool.database.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM offlineSnapshots") } == 0)
            #expect(try await pool.database.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM items") } == 1300)
            // No future member exists provisionally before the first atomic publication.
            #expect(try pool.database.offlineItemSelections().isEmpty)
            await publicationGate.open()
            try await cold.value
        } catch {
            cold.cancel()
            await publicationGate.open()
            _ = await cold.result
            throw error
        }
        await repository.setPublicationGate(nil)
        _ = try await recorder.wait { $0.vaults.first?.usableCount == 1300 }
        let coldState = try await IncrementalPoolStoredState.load(from: pool.database)
        let coldKeys = await keys.counts()
        #expect(coldState.items.count == 1300)
        #expect(coldState.descriptorIDs.count == 1300)
        #expect(coldKeys.lookups == 1300 && coldKeys.creations == 1)
        #expect(await fixture.viewer.calls().isEmpty)
        #expect(await repository.batchCounts() == Array(repeating: 32, count: 40) + [20])
        let coldReport = try probe.report(on: pool.database)
        for table in ["items", "autoFillDescriptors", "offlineItems", "offlineSnapshots"] { #expect(coldReport.rowCount(table, "insert") == 1300) }
        #expect(coldReport.writerCatalogProjections == 0 && coldReport.pointItemLookups == 0)
        try coldReport.emitCounts(phase: "cold-1300")

        try probe.reset(on: pool.database)
        try await fixture.sync(items)
        let warmState = try await IncrementalPoolStoredState.load(from: pool.database)
        #expect(warmState == coldState)
        #expect(await keys.counts() == coldKeys)
        #expect(await fixture.codec.counts().prepared == 1300)
        #expect(await repository.batchCounts().count == 41)
        #expect(await fixture.viewer.calls().isEmpty)
        let warmReport = try probe.report(on: pool.database)
        for table in ["items", "vaults", "autoFillDescriptors", "offlineItems", "offlineSnapshots"] {
            for operation in ["insert", "update", "delete"] { #expect(warmReport.rowCount(table, operation) == 0) }
        }
        // Capture authority still has real short-lived writes, not a zero-total-writes claim.
        #expect(warmReport.rowCount("offlineSyncCaptureItems", "insert") == 1300)
        #expect(warmReport.rowCount("offlineSyncCaptureItems", "delete") == 1300)
        #expect(warmReport.writerCatalogProjections == 0 && warmReport.pointItemLookups == 0)
        #expect(warmReport.statements["items.select"] == 1)
        #expect(warmReport.statements["autoFillDescriptors.select"] == 2)
        #expect(warmReport.statements["offlineSnapshots.select", default: 0] == 0)
        let warmCatalog = try await IncrementalPoolSQLProbe.catalog(in: pool.database)
        #expect(warmCatalog.selects == 3)
        #expect(warmCatalog.snapshot.vaults.first?.usableCount == 1300)
        try warmReport.emitCounts(phase: "unchanged-1300")

        try probe.reset(on: pool.database)
        items[0] = try incrementalSyncCLIItem(id: ids[0], modifyTime: "1970-01-01T00:00:03Z", title: "Changed scale item", url: "https://scale.example.test")
        try await fixture.sync(items)
        let changedState = try await IncrementalPoolStoredState.load(from: pool.database)
        let before = try #require(coldState.items.first { $0.id == ids[0] })
        let after = try #require(changedState.items.first { $0.id == ids[0] })
        #expect(after.revision != before.revision)
        #expect(after.sourceTime == Date(timeIntervalSince1970: 3))
        #expect(after.metadataGeneration == after.snapshotMetadataGeneration)
        #expect(changedState.items.filter { $0.id != ids[0] } == coldState.items.filter { $0.id != ids[0] })
        #expect(changedState.descriptorIDs == coldState.descriptorIDs)
        #expect(await keys.counts().lookups == coldKeys.lookups + 1)
        #expect(await keys.counts().creations == 1)
        #expect(await fixture.codec.counts().prepared == 1301)
        #expect(await fixture.codec.counts().peak == 1)
        #expect(await repository.batchCounts() == Array(repeating: 32, count: 40) + [20, 1])
        #expect(await fixture.viewer.calls().isEmpty)
        let changedReport = try probe.report(on: pool.database)
        for table in ["items", "autoFillDescriptors", "offlineSnapshots"] { #expect(changedReport.rowCount(table, "update") == 1) }
        #expect(changedReport.rowCount("offlineSnapshots", "insert") == 0)
        #expect(changedReport.writerCatalogProjections == 0 && changedReport.pointItemLookups == 0)
        try changedReport.emitCounts(phase: "one-change-1300")
        let expectedRefresh = after.refreshedAt
        _ = try await recorder.wait { value in
            value.itemGroups.flatMap(\.items).contains { $0.itemId == "item-0" && $0.title == "Changed scale item" && $0.lastRefreshedAt == expectedRefresh }
        }
        let changedCatalog = try await IncrementalPoolSQLProbe.catalog(in: pool.database)
        #expect(changedCatalog.selects == 3)
        #expect(changedCatalog.snapshot.vaults.first?.usableCount == 1300)
        print("Encrypted-pool catalog SELECTs: unchanged=\(warmCatalog.selects), changed=\(changedCatalog.selects); observation emissions=\(await recorder.emissionCount()) (coalescing allowed)")
        observing.cancel()
        _ = await observing.result
        await fixture.service.stop()
    }
}

/// Isolated encrypted pool; all values and key material are synthetic, never Keychain-backed.
private final class OfflineCatalogPoolFixture: Sendable {
    let root: URL
    let database: DatabaseManager
    let repository: OfflineSnapshotRepository

    init(seedCatalog: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("qa-catalog-\(UUID())", isDirectory: true)
        database = try DatabaseManager(path: root.appendingPathComponent("catalog.db").path, passphrase: Data(repeating: 37, count: 32))
        repository = OfflineSnapshotRepository(database: database)
        if seedCatalog {
            try database.upsertVaults([PassVault(id: "vault", name: "Vault", shareId: "share")])
            try database.upsertItems(["manual", "vault-only"].map { offlineTestMetadata(id: $0, vaultID: "vault") })
        }
    }

    func publish(itemID: String, kind: OfflineRequestKind, refreshedAt: Date = Date(timeIntervalSince1970: 800)) async throws -> EncryptedOfflineSnapshot {
        let generation = try await repository.offlineItemSelection(itemId: itemID)?.selectionGeneration
        let request = try #require(try await repository.beginRequest(
            itemID: itemID, vaultID: "vault", shareID: "share", kind: kind,
            expectations: .init(selectionGeneration: generation, metadataModifyTime: nil, itemType: nil)
        ))
        let repository = repository
        let codec = OfflineSnapshotCodec(keyMaterialProvider: OfflineFixtureKeys(), hasPersistedSnapshots: {
            try await repository.hasPersistedSnapshots()
        })
        let item = try offlineTestCLIItem(id: itemID, vaultID: "vault", shareID: "share", password: "synthetic")
        let snapshot = try await codec.prepareSnapshot(from: item, for: request)
        #expect(try await repository.publish(snapshot, for: request, refreshedAt: refreshedAt))
        return snapshot.snapshot
    }

    func setSnapshotSchema(_ version: Int) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE offlineSnapshots SET schemaVersion = ? WHERE itemId = 'manual'", arguments: [version])
        }
    }

    func setExclusion(_ excluded: Bool) async throws {
        try await database.writer.write { db in
            if excluded {
                try db.execute(sql: "INSERT INTO offlineItemExclusions (vaultId, itemId) VALUES ('vault', 'vault-only')")
            } else {
                try db.execute(sql: "DELETE FROM offlineItemExclusions WHERE itemId = 'vault-only'")
            }
        }
    }

    func remove() {
        try? database.writer.close()
        try? FileManager.default.removeItem(at: root)
    }
}
