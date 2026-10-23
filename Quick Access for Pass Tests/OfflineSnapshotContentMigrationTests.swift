import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("Offline snapshot content migration", .timeLimit(.minutes(1)))
struct OfflineSnapshotContentMigrationTests {
    @Test func v16UsesGenericContentRevisionAndPreservesV15WithoutSnapshotKeys() throws {
        let queue = try DatabaseQueue()
        // Isolated v15-shaped schema: synthetic bytes only, with no codec or key provider.
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE items (id TEXT PRIMARY KEY, title TEXT NOT NULL);
                CREATE TABLE vaults (id TEXT PRIMARY KEY);
                CREATE TABLE runProfiles (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
                CREATE TABLE runAuthDecisions (id INTEGER PRIMARY KEY, commandText TEXT NOT NULL);
                CREATE TABLE offlineItems (
                    itemId TEXT PRIMARY KEY, vaultId TEXT NOT NULL, isManuallySelected BOOLEAN NOT NULL,
                    selectionGeneration TEXT NOT NULL, metadataGeneration TEXT NOT NULL,
                    requestGeneration TEXT NOT NULL, cacheStatus TEXT NOT NULL, lastRefreshedAt DOUBLE
                );
                CREATE TABLE offlineVaults (vaultId TEXT PRIMARY KEY, policyGeneration TEXT NOT NULL);
                CREATE TABLE offlineItemExclusions (
                    itemId TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                    vaultId TEXT NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
                    PRIMARY KEY(itemId, vaultId)
                );
                CREATE TABLE offlineSyncCaptures (
                    id TEXT NOT NULL PRIMARY KEY, syncOperationID TEXT NOT NULL, lifecycleGeneration TEXT NOT NULL
                );
                CREATE TABLE offlineSyncCaptureVaults (
                    captureID TEXT NOT NULL REFERENCES offlineSyncCaptures(id) ON DELETE CASCADE,
                    vaultID TEXT NOT NULL, policyGeneration TEXT NOT NULL, PRIMARY KEY(captureID, vaultID)
                );
                CREATE TABLE offlineSyncCaptureItems (
                    captureID TEXT NOT NULL REFERENCES offlineSyncCaptures(id) ON DELETE CASCADE,
                    vaultID TEXT NOT NULL, itemID TEXT NOT NULL, selectionGeneration TEXT,
                    requestGeneration TEXT, pendingRequestID TEXT,
                    isManuallySelected BOOLEAN NOT NULL CHECK(isManuallySelected IN (0, 1)),
                    isExcluded BOOLEAN NOT NULL CHECK(isExcluded IN (0, 1)),
                    wasEligibleForVaultSelection BOOLEAN NOT NULL CHECK(wasEligibleForVaultSelection IN (0, 1)),
                    PRIMARY KEY(captureID, vaultID, itemID),
                    CHECK((selectionGeneration IS NULL AND requestGeneration IS NULL AND pendingRequestID IS NULL)
                        OR (selectionGeneration IS NOT NULL AND requestGeneration IS NOT NULL))
                );
                CREATE TABLE offlineSnapshots (
                    vaultId TEXT NOT NULL, itemId TEXT NOT NULL, schemaVersion INTEGER NOT NULL,
                    snapshotRevision TEXT NOT NULL, keyFingerprint BLOB NOT NULL, encryptedPayload BLOB NOT NULL,
                    sourceModifyTime DATETIME, metadataGeneration TEXT, PRIMARY KEY (vaultId, itemId)
                );
                INSERT INTO items VALUES ('item', 'Synthetic alias'), ('excluded', 'Synthetic excluded item');
                INSERT INTO vaults VALUES ('vault');
                INSERT INTO runProfiles VALUES (1, 'Synthetic profile');
                INSERT INTO runAuthDecisions VALUES (1, 'synthetic-tool --version');
                INSERT INTO offlineItems VALUES ('item', 'vault', 1, 'selection', 'metadata', 'request', 'cached', 41);
                INSERT INTO offlineVaults VALUES ('vault', 'policy');
                INSERT INTO offlineItemExclusions VALUES ('excluded', 'vault');
                INSERT INTO offlineSyncCaptures VALUES ('capture', 'operation', 'lifecycle');
                INSERT INTO offlineSyncCaptureVaults VALUES ('capture', 'vault', 'policy');
                INSERT INTO offlineSyncCaptureItems VALUES ('capture', 'vault', 'item', 'selection', 'request', NULL, 1, 0, 1);
                INSERT INTO offlineSnapshots VALUES ('vault', 'item', 1, 'revision', ?, ?, 2.123456, 'metadata');
                """, arguments: [Data(repeating: 7, count: 32), Data(repeating: 8, count: 64)])
        }
        let tables = ["items", "vaults", "runProfiles", "runAuthDecisions", "offlineItems", "offlineVaults",
                      "offlineItemExclusions", "offlineSyncCaptures", "offlineSyncCaptureVaults", "offlineSyncCaptureItems"]
        let before = try queue.read { db in
            try tables.map { try Row.fetchAll(db, sql: "SELECT * FROM \($0)") }
        }
        let snapshotColumns = "vaultId, itemId, schemaVersion, snapshotRevision, keyFingerprint, encryptedPayload, sourceModifyTime, metadataGeneration"
        let oldSnapshot = try queue.read { try Row.fetchAll($0, sql: "SELECT \(snapshotColumns) FROM offlineSnapshots") }
        var migrator = DatabaseMigrator()
        DatabaseManager.registerOfflineSnapshotContentMigration(&migrator)
        try migrator.migrate(queue)

        try queue.read { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(offlineSnapshots)")
                .map { $0["name"] as String }
            #expect(columns.contains("contentRevision"))
            #expect(columns.contains("aliasEmailContentVersion") == false)
        }
        try queue.read { db in
            let after = try tables.map { try Row.fetchAll(db, sql: "SELECT * FROM \($0)") }
            let snapshot = try Row.fetchAll(db, sql: "SELECT \(snapshotColumns) FROM offlineSnapshots")
            let marker = try Int.fetchOne(db, sql: "SELECT contentRevision FROM offlineSnapshots")
            let migrations = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            #expect(after == before)
            #expect(snapshot == oldSnapshot)
            #expect(marker == 0)
            #expect(migrations == ["v16"])
        }
        for (value, expectedCode) in [("-1", ResultCode.SQLITE_CONSTRAINT_CHECK), ("NULL", .SQLITE_CONSTRAINT_NOTNULL)] {
            do {
                try queue.write { try $0.execute(sql: "UPDATE offlineSnapshots SET contentRevision = \(value)") }
                Issue.record("Invalid content revision unexpectedly committed")
            } catch let error as DatabaseError {
                #expect(error.extendedResultCode == expectedCode)
            }
            try queue.read { db in
                let marker = try Int.fetchOne(db, sql: "SELECT contentRevision FROM offlineSnapshots")
                let snapshot = try Row.fetchAll(db, sql: "SELECT \(snapshotColumns) FROM offlineSnapshots")
                #expect(marker == 0)
                #expect(snapshot == oldSnapshot)
            }
        }
        try queue.write { try $0.execute(sql: "UPDATE offlineSnapshots SET contentRevision = 1") }
        try queue.read { db in
            let marker = try Int.fetchOne(db, sql: "SELECT contentRevision FROM offlineSnapshots")
            let snapshot = try Row.fetchAll(db, sql: "SELECT \(snapshotColumns) FROM offlineSnapshots")
            #expect(marker == 1)
            #expect(snapshot == oldSnapshot)
        }
    }

    @Test func freshDatabaseRegistersV16WithDefaultZeroNonnullableMarker() throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("synthetic".utf8))
        try database.reader.read { db in
            #expect(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations").contains("v16"))
            let column = try #require(try Row.fetchAll(db, sql: "PRAGMA table_info(offlineSnapshots)")
                .first { ($0["name"] as String) == "contentRevision" })
            #expect(column["type"] as String == "INTEGER")
            #expect(column["notnull"] as Int == 1)
            #expect(column["dflt_value"] as String == "0")
        }
    }
}
