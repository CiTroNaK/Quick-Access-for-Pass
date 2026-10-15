import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("Incremental Offline Mode migration", .timeLimit(.minutes(1)))
struct IncrementalOfflineMigrationTests {
    @Test("fresh schema contains durable generations and nullable snapshot baselines")
    func freshSchemaHasDurableFreshness() throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("synthetic".utf8))
        try database.reader.read { db in
            let selections = try columns("offlineItems", in: db)
            #expect(selections.contains("metadataGeneration"))
            #expect(selections.contains("requestGeneration"))
            let snapshots = try columns("offlineSnapshots", in: db)
            #expect(snapshots.contains("sourceModifyTime"))
            #expect(snapshots.contains("metadataGeneration"))
            let migrations = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            #expect(migrations.contains("v15"))
        }
    }

    @Test("capture tables contain ownership metadata only")
    func captureSchemaIsMetadataOnly() throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("synthetic".utf8))
        try database.reader.read { db in
            let captures = try columns("offlineSyncCaptures", in: db)
            let vaults = try columns("offlineSyncCaptureVaults", in: db)
            let items = try columns("offlineSyncCaptureItems", in: db)
            #expect(captures == ["id", "syncOperationID", "lifecycleGeneration"])
            #expect(vaults == ["captureID", "vaultID", "policyGeneration"])
            #expect(items == [
                "captureID", "vaultID", "itemID", "selectionGeneration", "requestGeneration", "pendingRequestID",
                "isManuallySelected", "isExcluded", "wasEligibleForVaultSelection"
            ])
        }
    }

    @Test("schema-only migration leaves ordinary catalog, profiles and remembered decisions untouched")
    func schemaOnlyMigrationPreservesOrdinaryRows() throws {
        let queue = try DatabaseQueue()
        // Isolated schema fixture, deliberately containing no offline content or snapshot keys.
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE items (id TEXT PRIMARY KEY, title TEXT NOT NULL);
                CREATE TABLE runProfiles (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
                CREATE TABLE runAuthDecisions (id INTEGER PRIMARY KEY, commandText TEXT NOT NULL);
                CREATE TABLE offlineItems (itemId TEXT PRIMARY KEY, vaultId TEXT NOT NULL);
                CREATE TABLE offlineSnapshots (vaultId TEXT NOT NULL, itemId TEXT NOT NULL);
                INSERT INTO items VALUES ('ordinary-item', 'Synthetic catalog title');
                INSERT INTO runProfiles VALUES (1, 'Synthetic profile');
                INSERT INTO runAuthDecisions VALUES (1, 'synthetic-tool --version');
                """)
        }
        var migrator = DatabaseMigrator()
        DatabaseManager.registerIncrementalOfflineMigration(&migrator)
        try migrator.migrate(queue)
        try queue.read { db in
            let title = try String.fetchOne(db, sql: "SELECT title FROM items")
            let profile = try String.fetchOne(db, sql: "SELECT name FROM runProfiles")
            let command = try String.fetchOne(db, sql: "SELECT commandText FROM runAuthDecisions")
            #expect(title == "Synthetic catalog title")
            #expect(profile == "Synthetic profile")
            #expect(command == "synthetic-tool --version")
        }
    }

    @Test("catalog removal retains admission evidence; capture removal cascades its children")
    func captureForeignKeysRetainKnownMembership() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let captureID = UUID().uuidString
        try await fixture.database.writer.write { db in
            try db.execute(sql: "INSERT INTO offlineSyncCaptures VALUES (?, ?, ?)",
                           arguments: [captureID, UUID().uuidString, UUID().uuidString])
            try db.execute(sql: "INSERT INTO offlineSyncCaptureVaults VALUES (?, 'vault', ?)",
                           arguments: [captureID, UUID().uuidString])
            try db.execute(sql: """
                INSERT INTO offlineSyncCaptureItems VALUES (?, 'vault', 'item', NULL, NULL, NULL, 0, 0, 1)
                """, arguments: [captureID])
            // Test-target-only catalog setup mutation; no plaintext or real database is involved.
            try db.execute(sql: "DELETE FROM items WHERE id = 'item'; DELETE FROM vaults WHERE id = 'vault'")
            let retainedItems = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineSyncCaptureItems")
            let retainedVaults = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineSyncCaptureVaults")
            #expect(retainedItems == 1)
            #expect(retainedVaults == 1)
            try db.execute(sql: "DELETE FROM offlineSyncCaptures WHERE id = ?", arguments: [captureID])
            let remainingItems = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineSyncCaptureItems")
            let remainingVaults = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineSyncCaptureVaults")
            #expect(remainingItems == 0)
            #expect(remainingVaults == 0)
        }
    }

    @Test("new selections own distinct valid metadata and request generations")
    func newSelectionsInitializeGenerations() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["first", "second"])
        let first = try #require(try await fixture.repository.beginRequest(
            itemID: "first", vaultID: "vault", shareID: "share", kind: .selection
        ))
        let second = try #require(try await fixture.repository.beginRequest(
            itemID: "second", vaultID: "vault", shareID: "share", kind: .selection
        ))
        let generations = [first.selectionGeneration, first.metadataGeneration, first.requestGeneration,
                           second.selectionGeneration, second.metadataGeneration, second.requestGeneration]
        #expect(Set(generations).count == 6)
        try await fixture.database.reader.read { db in
            let stored = try String.fetchAll(db, sql: "SELECT metadataGeneration FROM offlineItems ORDER BY itemId")
            #expect(stored == [first.metadataGeneration.uuidString, second.metadataGeneration.uuidString])
        }
    }

    private func columns(_ table: String, in db: Database) throws -> Set<String> {
        // Fixed test-authored identifiers only, never external input.
        Set(try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").compactMap { $0["name"] as String? })
    }
}
