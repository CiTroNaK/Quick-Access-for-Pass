import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("DatabaseManager Migration v12")
struct DatabaseManagerMigrationV12Tests {
    private let passphrase = Data("offline-v12-migration-test".utf8)

    @Test("fresh schema has selection policy metadata")
    func freshSchemaHasSelectionPolicyMetadata() throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try database.reader.read { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(offlineItems)")
            let names = Set(columns.compactMap { $0["name"] as String? })
            #expect(names.contains("isManuallySelected"))
            #expect(names.contains("selectionGeneration"))
            #expect(try String.fetchOne(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'offlineItemExclusions'") != nil)
        }
    }

    @Test("v11 upgrade preserves selected ciphertext but does not expand vault consent")
    func v11FixturePreservesCiphertextAndRemovesPermissionOnlyRows() throws {
        let fixture = try makeV11Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let database = try DatabaseManager(path: fixture.databaseURL.path, passphrase: passphrase)
        let upgraded = try database.reader.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM offlineSnapshots WHERE itemId = 'item'")
        }
        #expect(upgraded?["snapshotRevision"] as String? == fixture.revision)
        #expect(upgraded?["keyFingerprint"] as Data? == fixture.fingerprint)
        #expect(upgraded?["encryptedPayload"] as Data? == fixture.payload)
        #expect(upgraded?["schemaVersion"] as Int? == 1)
        let selected = try database.reader.read { db in
            try Row.fetchOne(db, sql: "SELECT selectedAt, lastRefreshedAt, cacheStatus FROM offlineItems WHERE itemId = 'item'")
        }
        #expect(selected?["selectedAt"] as Date? == Date(timeIntervalSince1970: 1))
        #expect(selected?["lastRefreshedAt"] as Date? == Date(timeIntervalSince1970: 2))
        #expect(selected?["cacheStatus"] as String? == "cached")
        let vaultColumns = try database.reader.read { db in
            Set(try Row.fetchAll(db, sql: "PRAGMA table_info(offlineVaults)").compactMap { $0["name"] as String? })
        }
        #expect(vaultColumns.contains("policyGeneration"))
        #expect(try database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineVaults")
        } == 0)
        #expect(try database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT isManuallySelected FROM offlineItems WHERE itemId = 'item'")
        } == 1)
        let generation = try database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT selectionGeneration FROM offlineItems WHERE itemId = 'item'")
        }
        #expect(UUID(uuidString: generation ?? "") != nil)
        #expect(generation != "00000000-0000-0000-0000-000000000000")
    }

    @Test("selection flags are constrained and exclusions cascade with metadata")
    func policyConstraintsAndExclusionCascades() throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try database.upsertVaults([PassVault(id: "vault", name: "Vault")])
        try database.upsertItems([PassItem(
            id: "item", vaultId: "vault", title: "Item", itemType: .login, subtitle: "",
            url: nil, hasTOTP: false, state: "Active", createTime: .now, modifyTime: .now,
            useCount: 0, lastUsedAt: nil
        )])
        try database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO offlineItems
                    (itemId, vaultId, selectedAt, lastRefreshedAt, cacheStatus, pendingRequestId, isManuallySelected, selectionGeneration)
                    VALUES ('item', 'vault', ?, NULL, 'selected', NULL, 1, ?)
                    """,
                arguments: [Date(), UUID().uuidString]
            )
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "UPDATE offlineItems SET isManuallySelected = 2 WHERE itemId = 'item'")
            }
            let exclusionForeignKeys = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(offlineItemExclusions)")
            let itemCascade = exclusionForeignKeys.contains {
                ($0["table"] as String?) == "items" && ($0["from"] as String?) == "itemId" && ($0["to"] as String?) == "id" && ($0["on_delete"] as String?)?.uppercased() == "CASCADE"
            }
            let vaultCascade = exclusionForeignKeys.contains {
                ($0["table"] as String?) == "vaults" && ($0["from"] as String?) == "vaultId" && ($0["to"] as String?) == "id" && ($0["on_delete"] as String?)?.uppercased() == "CASCADE"
            }
            #expect(itemCascade)
            #expect(vaultCascade)
            try db.execute(sql: "INSERT INTO offlineItemExclusions (itemId, vaultId) VALUES ('item', 'vault')")
            try db.execute(sql: "DELETE FROM items WHERE id = 'item'")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineItemExclusions") == 0)
            try db.execute(
                sql: "INSERT INTO items (id, vaultId, title, itemType, state, createTime, modifyTime) VALUES ('item', 'vault', 'Item', 'login', 'Active', ?, ?)",
                arguments: [Date(), Date()]
            )
            try db.execute(sql: "INSERT INTO offlineItemExclusions (itemId, vaultId) VALUES ('item', 'vault')")
            try db.execute(sql: "DELETE FROM vaults WHERE id = 'vault'")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineItemExclusions") == 0)
        }
    }

    private func makeV11Fixture() throws -> (root: URL, databaseURL: URL, revision: String, fingerprint: Data, payload: Data) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("app.db")
        var configuration = Configuration()
        configuration.prepareDatabase { db in try db.usePassphrase(passphrase) }
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        let revision = UUID().uuidString
        let fingerprint = Data(repeating: 7, count: 32)
        let payload = Data(repeating: 8, count: 40)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE vaults (id TEXT PRIMARY KEY, name TEXT NOT NULL, shareId TEXT NOT NULL);
                CREATE TABLE items (
                    id TEXT PRIMARY KEY, vaultId TEXT NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
                    title TEXT NOT NULL, itemType TEXT NOT NULL, subtitle TEXT NOT NULL DEFAULT '',
                    url TEXT, hasTOTP BOOLEAN NOT NULL DEFAULT 0, state TEXT NOT NULL,
                    createTime DATETIME NOT NULL, modifyTime DATETIME NOT NULL,
                    useCount INTEGER NOT NULL DEFAULT 0, lastUsedAt DATETIME,
                    fieldKeysJSON TEXT NOT NULL DEFAULT '[]'
                );
                CREATE TABLE runProfiles (id INTEGER PRIMARY KEY, name TEXT NOT NULL, slug TEXT NOT NULL, createdAt DATETIME NOT NULL, cacheDuration TEXT NOT NULL);
                CREATE TABLE runProfileEnvMappings (id INTEGER PRIMARY KEY, profileId INTEGER NOT NULL, envVariable TEXT NOT NULL, secretReference TEXT NOT NULL);
                CREATE TABLE sshAuthDecisions (appIdentifier TEXT NOT NULL, keyFingerprint TEXT NOT NULL, expiresAt DATETIME, appTeamID TEXT);
                CREATE TABLE sshBatchModeDecisions (
                    keyFingerprint TEXT NOT NULL, host TEXT NOT NULL, keyName TEXT,
                    allowed BOOLEAN NOT NULL, createdAt DATETIME NOT NULL,
                    appIdentifier TEXT, appTeamID TEXT
                );
                CREATE TABLE runAuthDecisions (appIdentifier TEXT NOT NULL, subcommand TEXT NOT NULL, profileSlug TEXT NOT NULL, expiresAt DATETIME, appTeamID TEXT);
                CREATE TABLE autoFillDescriptors (
                    id TEXT PRIMARY KEY, vaultID TEXT NOT NULL, itemID TEXT NOT NULL,
                    shareID TEXT NOT NULL, title TEXT NOT NULL, username TEXT NOT NULL,
                    serviceIdentifier TEXT NOT NULL, hasTOTP BOOLEAN NOT NULL
                );
                CREATE TABLE autoFillAppAssociations (serviceIdentifier TEXT NOT NULL, serviceKind TEXT NOT NULL, descriptorID TEXT NOT NULL, serviceDisplayName TEXT, createdAt DATETIME NOT NULL);
                CREATE TABLE offlineVaults (vaultId TEXT PRIMARY KEY REFERENCES vaults(id) ON DELETE CASCADE, enabledAt DATETIME NOT NULL);
                CREATE TABLE offlineItems (
                    itemId TEXT PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
                    vaultId TEXT NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
                    selectedAt DATETIME NOT NULL, lastRefreshedAt DATETIME,
                    cacheStatus TEXT NOT NULL, pendingRequestId TEXT
                );
                CREATE UNIQUE INDEX offlineItems_identity ON offlineItems(itemId, vaultId);
                CREATE TABLE offlineSnapshots (
                    vaultId TEXT NOT NULL, itemId TEXT NOT NULL,
                    schemaVersion INTEGER NOT NULL CHECK(schemaVersion BETWEEN 1 AND 255),
                    snapshotRevision TEXT NOT NULL,
                    keyFingerprint BLOB NOT NULL CHECK(typeof(keyFingerprint) = 'blob' AND length(keyFingerprint) = 32),
                    encryptedPayload BLOB NOT NULL CHECK(typeof(encryptedPayload) = 'blob' AND length(encryptedPayload) BETWEEN 28 AND 4194332),
                    PRIMARY KEY(vaultId, itemId),
                    FOREIGN KEY(itemId, vaultId) REFERENCES offlineItems(itemId, vaultId) ON DELETE CASCADE
                );
                CREATE TABLE grdb_migrations (identifier TEXT PRIMARY KEY);
                """)
            for version in 1...11 {
                try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: ["v\(version)"])
            }
            try db.execute(sql: "INSERT INTO vaults VALUES ('vault', 'Vault', 'share')")
            try db.execute(
                sql: "INSERT INTO items (id, vaultId, title, itemType, state, createTime, modifyTime) VALUES ('item', 'vault', 'Item', 'login', 'Active', ?, ?)",
                arguments: [Date(timeIntervalSince1970: 1), Date(timeIntervalSince1970: 2)]
            )
            try db.execute(sql: "INSERT INTO offlineVaults VALUES ('vault', ?)", arguments: [Date(timeIntervalSince1970: 1)])
            try db.execute(sql: "INSERT INTO offlineItems VALUES ('item', 'vault', ?, ?, 'cached', NULL)", arguments: [Date(timeIntervalSince1970: 1), Date(timeIntervalSince1970: 2)])
            try db.execute(sql: "INSERT INTO offlineSnapshots VALUES ('vault', 'item', 1, ?, ?, ?)", arguments: [revision, fingerprint, payload])
        }
        return (root, databaseURL, revision, fingerprint, payload)
    }
}
