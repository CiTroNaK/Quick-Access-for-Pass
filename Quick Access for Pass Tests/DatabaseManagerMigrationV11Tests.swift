import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("DatabaseManager Migration v11")
struct DatabaseManagerMigrationV11Tests {
    private let passphrase = Data("offline-v11-migration-test".utf8)

    @Test("snapshot schema and connection protections exist")
    func snapshotSchemaAndConnectionProtectionExist() throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))

        try database.reader.read { connection in
            let snapshotTable = try String.fetchOne(
                connection,
                sql: "SELECT name FROM sqlite_master WHERE name = 'offlineSnapshots'"
            )
            let foreignKeys = try Int.fetchOne(connection, sql: "PRAGMA foreign_keys")
            let secureDelete = try Int.fetchOne(connection, sql: "PRAGMA secure_delete")
            let tempStore = try Int.fetchOne(connection, sql: "PRAGMA temp_store")
            let memorySecurity = try Int.fetchOne(connection, sql: "PRAGMA cipher_memory_security")
            #expect(snapshotTable != nil)
            #expect(foreignKeys == 1)
            #expect(secureDelete == 1)
            #expect(tempStore == 2)
            #expect(memorySecurity == 1)
        }
    }

    @Test("snapshot constraints reject invalid records and cascade with their selection")
    func snapshotConstraintsAndCascade() throws {
        let database = try DatabaseManager(inMemory: true, passphrase: passphrase)
        try database.upsertVaults([PassVault(id: "vault", name: "Vault")])
        try database.upsertItems([item(id: "item", vaultID: "vault")])
        try database.selectWholeOfflineVault("vault")
        try database.selectManualOfflineItem(itemId: "item", vaultId: "vault")

        let validFingerprint = Data(repeating: 1, count: 32)
        let validPayload = Data(repeating: 2, count: OfflineSnapshotLimits.ciphertextBytes)
        try database.writer.write { connection in
            try connection.execute(
                sql: """
                    INSERT INTO offlineSnapshots
                    (vaultId, itemId, schemaVersion, snapshotRevision, keyFingerprint, encryptedPayload)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: ["vault", "item", OfflineSnapshotLimits.schemaVersion, UUID().uuidString, validFingerprint, validPayload]
            )
        }

        try database.writer.write { connection in
            #expect(throws: DatabaseError.self) {
                try connection.execute(
                    sql: """
                        INSERT INTO offlineSnapshots
                        (vaultId, itemId, schemaVersion, snapshotRevision, keyFingerprint, encryptedPayload)
                        VALUES ('orphan-vault', 'orphan-item', 1, 'orphan', ?, ?)
                        """,
                    arguments: [validFingerprint, validPayload]
                )
            }
            #expect(throws: DatabaseError.self) {
                try connection.execute(
                    sql: """
                        INSERT INTO offlineSnapshots
                        (vaultId, itemId, schemaVersion, snapshotRevision, keyFingerprint, encryptedPayload)
                        VALUES ('wrong-vault', 'item', 1, 'mismatch', ?, ?)
                        """,
                    arguments: [validFingerprint, validPayload]
                )
            }
            #expect(throws: DatabaseError.self) {
                try connection.execute(
                    sql: """
                        INSERT INTO offlineSnapshots
                        (vaultId, itemId, schemaVersion, snapshotRevision, keyFingerprint, encryptedPayload)
                        VALUES ('vault', 'item', 1, 'short-fingerprint', ?, ?)
                        """,
                    arguments: [Data(repeating: 1, count: 31), validPayload]
                )
            }
            #expect(throws: DatabaseError.self) {
                try connection.execute(
                    sql: """
                        INSERT INTO offlineSnapshots
                        (vaultId, itemId, schemaVersion, snapshotRevision, keyFingerprint, encryptedPayload)
                        VALUES ('vault', 'item', 1, 'text-fingerprint', 'not-a-blob', ?)
                        """,
                    arguments: [validPayload]
                )
            }
            #expect(throws: DatabaseError.self) {
                try connection.execute(
                    sql: """
                        INSERT INTO offlineSnapshots
                        (vaultId, itemId, schemaVersion, snapshotRevision, keyFingerprint, encryptedPayload)
                        VALUES ('vault', 'item', 1, 'small-payload', ?, ?)
                        """,
                    arguments: [validFingerprint, Data(repeating: 2, count: 27)]
                )
            }
            #expect(throws: DatabaseError.self) {
                try connection.execute(
                    sql: """
                        INSERT INTO offlineSnapshots
                        (vaultId, itemId, schemaVersion, snapshotRevision, keyFingerprint, encryptedPayload)
                        VALUES ('vault', 'item', 1, 'large-payload', ?, ?)
                        """,
                    arguments: [validFingerprint, Data(repeating: 2, count: OfflineSnapshotLimits.ciphertextBytes + 1)]
                )
            }
        }

        _ = try database.removeOfflineItem(itemId: "item")
        #expect(try database.reader.read { connection in
            try Int.fetchOne(connection, sql: "SELECT COUNT(*) FROM offlineSnapshots")
        } == 0)
    }

    @Test("v10 fixture upgrades without changing ordinary data or opening a cache file")
    func v10FixturePreservesOrdinaryData() throws {
        let fixture = try makeV10Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cacheURL = fixture.root.appendingPathComponent("offline-cache.db")
        let cacheBytes = Data("must-not-open".utf8)
        try cacheBytes.write(to: cacheURL)

        let database = try DatabaseManager(path: fixture.databaseURL.path, passphrase: passphrase)

        #expect(try database.reader.read { connection in
            try String.fetchOne(connection, sql: "SELECT name FROM vaults WHERE id = 'vault'")
        } == "Vault")
        #expect(try database.reader.read { connection in
            try String.fetchOne(connection, sql: "SELECT title FROM items WHERE id = 'item'")
        } == "Item")
        #expect(try database.reader.read { connection in
            try String.fetchOne(connection, sql: "SELECT name FROM runProfiles WHERE id = 1")
        } == "Run profile")
        #expect(try database.reader.read { connection in
            try String.fetchOne(connection, sql: "SELECT appIdentifier FROM sshAuthDecisions")
        } == "com.example.app")
        #expect(try database.reader.read { connection in
            try String.fetchOne(connection, sql: "SELECT appIdentifier FROM runAuthDecisions")
        } == "com.example.app")
        #expect(try Data(contentsOf: cacheURL) == cacheBytes)
    }

    private func item(id: String, vaultID: String) -> PassItem {
        PassItem(
            id: id, vaultId: vaultID, title: "Item", itemType: .login, subtitle: "",
            url: nil, hasTOTP: false, state: "Active", createTime: .now, modifyTime: .now,
            useCount: 0, lastUsedAt: nil
        )
    }

    private func makeV10Fixture() throws -> (root: URL, databaseURL: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("app.db")
        var configuration = Configuration()
        configuration.prepareDatabase { connection in try connection.usePassphrase(passphrase) }
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        try queue.write { connection in
            try connection.execute(sql: """
                CREATE TABLE vaults (id TEXT PRIMARY KEY, name TEXT NOT NULL, shareId TEXT NOT NULL);
                CREATE TABLE items (
                    id TEXT PRIMARY KEY, vaultId TEXT NOT NULL, title TEXT NOT NULL,
                    itemType TEXT NOT NULL, subtitle TEXT NOT NULL DEFAULT '', url TEXT,
                    hasTOTP BOOLEAN NOT NULL DEFAULT 0, state TEXT NOT NULL,
                    createTime DATETIME NOT NULL, modifyTime DATETIME NOT NULL,
                    useCount INTEGER NOT NULL DEFAULT 0, lastUsedAt DATETIME,
                    fieldKeysJSON TEXT NOT NULL DEFAULT '[]'
                );
                CREATE TABLE offlineVaults (vaultId TEXT PRIMARY KEY, enabledAt DATETIME NOT NULL);
                CREATE TABLE offlineItems (
                    itemId TEXT PRIMARY KEY, vaultId TEXT NOT NULL, selectedAt DATETIME NOT NULL,
                    lastRefreshedAt DATETIME, cacheStatus TEXT NOT NULL
                );
                CREATE TABLE runProfiles (id INTEGER PRIMARY KEY, name TEXT NOT NULL, slug TEXT NOT NULL, createdAt DATETIME NOT NULL, cacheDuration TEXT NOT NULL);
                CREATE TABLE sshAuthDecisions (appIdentifier TEXT NOT NULL, keyFingerprint TEXT NOT NULL, expiresAt DATETIME, appTeamID TEXT);
                CREATE TABLE runAuthDecisions (appIdentifier TEXT NOT NULL, subcommand TEXT NOT NULL, profileSlug TEXT NOT NULL, expiresAt DATETIME, appTeamID TEXT);
                CREATE TABLE grdb_migrations (identifier TEXT PRIMARY KEY);
                """)
            for version in 1...10 {
                try connection.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: ["v\(version)"])
            }
            try connection.execute(sql: "INSERT INTO vaults VALUES ('vault', 'Vault', 'share')")
            try connection.execute(
                sql: "INSERT INTO items (id, vaultId, title, itemType, state, createTime, modifyTime) VALUES ('item', 'vault', 'Item', 'login', 'Active', ?, ?)",
                arguments: [Date(), Date()]
            )
            try connection.execute(sql: "INSERT INTO runProfiles VALUES (1, 'Run profile', 'run-profile', ?, '5 minutes')", arguments: [Date()])
            try connection.execute(sql: "INSERT INTO sshAuthDecisions VALUES ('com.example.app', 'fingerprint', NULL, NULL)")
            try connection.execute(sql: "INSERT INTO runAuthDecisions VALUES ('com.example.app', 'run', 'run-profile', NULL, NULL)")
        }
        return (root, databaseURL)
    }
}
