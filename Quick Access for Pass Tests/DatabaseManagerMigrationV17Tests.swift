import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("Folder catalog migration v17")
struct DatabaseManagerMigrationV17Tests {
    @Test("v17 is additive and does not access or convert old snapshot bytes")
    func additiveMigration() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE vaults (id TEXT PRIMARY KEY);
                CREATE TABLE items (id TEXT PRIMARY KEY, vaultId TEXT, title TEXT);
                CREATE TABLE offlineItems (itemId TEXT PRIMARY KEY, isManuallySelected BOOLEAN);
                CREATE TABLE offlineVaults (vaultId TEXT PRIMARY KEY, policyGeneration TEXT);
                CREATE TABLE offlineSnapshots (itemId TEXT PRIMARY KEY, encryptedPayload BLOB, contentRevision INTEGER);
                CREATE TABLE offlineSyncCaptures (id TEXT PRIMARY KEY);
                CREATE TABLE runProfiles (id INTEGER PRIMARY KEY, name TEXT);
                INSERT INTO vaults VALUES ('vault');
                INSERT INTO items VALUES ('item', 'vault', 'Synthetic item');
                INSERT INTO offlineItems VALUES ('item', 1);
                INSERT INTO offlineVaults VALUES ('vault', 'policy');
                INSERT INTO offlineSnapshots VALUES ('item', ?, 0);
                INSERT INTO runProfiles VALUES (1, 'Synthetic profile');
                """, arguments: [Data(repeating: 7, count: 64)])
        }
        let tables = ["vaults", "items", "offlineItems", "offlineVaults", "offlineSnapshots", "runProfiles"]
        let before = try queue.read { db in try tables.map { try Row.fetchAll(db, sql: "SELECT * FROM \($0)") } }
        var migrator = DatabaseMigrator()
        DatabaseManager.registerFolderMigration(&migrator)
        try migrator.migrate(queue)
        try queue.read { (db: Database) throws -> Void in
            #expect(try tables.map { try Row.fetchAll(db, sql: "SELECT * FROM \($0)") } == before)
            #expect(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations") == ["v17"])
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
        // No codec/key provider is available to this isolated migration fixture.
    }

    @Test("fresh databases register all seventeen migrations and six metadata-only tables")
    func freshSchema() throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("synthetic".utf8))
        try database.reader.read { (db: Database) throws -> Void in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations") == 17)
            for table in ["folders", "folderAncestors", "folderCatalogState", "folderItemMemberships", "offlineFolders", "offlineSyncCaptureFolders"] {
                #expect(try db.tableExists(table))
            }
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    @Test("capture evidence outlives live policy deletion but cascades with its capture")
    func captureLifetime() throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("synthetic".utf8))
        try database.upsertVaults([PassVault(id: "vault", name: "Vault", shareId: "share")])
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO folders VALUES ('vault', 'folder', 'Synthetic folder', NULL);
                INSERT INTO offlineFolders VALUES ('vault', 'folder', 'policy', 1);
                INSERT INTO offlineSyncCaptures VALUES ('capture', 'operation', 'lifecycle');
                INSERT INTO offlineSyncCaptureFolders VALUES ('capture', 'vault', 'folder', 'policy');
                DELETE FROM folders;
                """)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineFolders") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineSyncCaptureFolders") == 1)
            try db.execute(sql: "DELETE FROM offlineSyncCaptures")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineSyncCaptureFolders") == 0)
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }
}
