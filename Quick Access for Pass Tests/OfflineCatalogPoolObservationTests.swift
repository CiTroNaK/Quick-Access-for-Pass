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

/// Isolated encrypted pool; all values and key material are synthetic, never Keychain-backed.
private final class OfflineCatalogPoolFixture: Sendable {
    let root: URL
    let database: DatabaseManager
    let repository: OfflineSnapshotRepository

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("qa-catalog-\(UUID())", isDirectory: true)
        database = try DatabaseManager(path: root.appendingPathComponent("catalog.db").path, passphrase: Data(repeating: 37, count: 32))
        repository = OfflineSnapshotRepository(database: database)
        try database.upsertVaults([PassVault(id: "vault", name: "Vault", shareId: "share")])
        try database.upsertItems(["manual", "vault-only"].map { offlineTestMetadata(id: $0, vaultID: "vault") })
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
        return snapshot
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
