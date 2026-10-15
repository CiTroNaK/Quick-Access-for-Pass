import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("DatabaseManager Migration v10")
struct DatabaseManagerMigrationV10Tests {
    private let passphrase = Data("offline-migration-test".utf8)

    @Test("v9 fixture upgrades with offline catalog tables, cascades, and preserved data")
    func upgradeFromV9PreservesDataAndCascades() throws {
        let fixture = try makeV9Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let database = try DatabaseManager(path: fixture.databaseURL.path, passphrase: passphrase)

        let schema = try database.reader.read { db in
            (
                try db.columns(in: "offlineVaults").map(\.name),
                try db.columns(in: "offlineItems").map(\.name)
            )
        }
        #expect(Set(schema.0) == ["vaultId", "enabledAt", "policyGeneration"])
        #expect(Set(schema.1) == [
            "itemId", "vaultId", "selectedAt", "lastRefreshedAt", "cacheStatus", "pendingRequestId",
            "isManuallySelected", "selectionGeneration", "metadataGeneration", "requestGeneration"
        ])

        let preservedData = try database.reader.read { db in
            (
                try String.fetchOne(db, sql: "SELECT shareId FROM vaults WHERE id = 'vault-a'"),
                try String.fetchOne(db, sql: "SELECT title FROM items WHERE id = 'item-a'"),
                try String.fetchOne(db, sql: "SELECT username FROM autoFillDescriptors WHERE id = 'descriptor-a'"),
                try String.fetchOne(db, sql: "SELECT serviceDisplayName FROM autoFillAppAssociations WHERE descriptorID = 'descriptor-a'")
            )
        }
        #expect(preservedData.0 == "share-a")
        #expect(preservedData.1 == "Legacy A")
        #expect(preservedData.2 == "a@example.com")
        #expect(preservedData.3 == "Legacy App A")

        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO offlineVaults (vaultId, enabledAt, policyGeneration) VALUES ('vault-a', ?, ?)", arguments: [Date(timeIntervalSince1970: 10), UUID().uuidString])
            try db.execute(sql: "INSERT INTO offlineVaults (vaultId, enabledAt, policyGeneration) VALUES ('vault-b', ?, ?)", arguments: [Date(timeIntervalSince1970: 10), UUID().uuidString])
            try db.execute(
                sql: """
                    INSERT INTO offlineItems
                    (itemId, vaultId, selectedAt, lastRefreshedAt, cacheStatus, isManuallySelected, selectionGeneration)
                    VALUES ('item-a', 'vault-a', ?, NULL, 'cached', 1, ?)
                    """,
                arguments: [Date(timeIntervalSince1970: 11), UUID().uuidString]
            )
            try db.execute(
                sql: """
                    INSERT INTO offlineItems
                    (itemId, vaultId, selectedAt, lastRefreshedAt, cacheStatus, isManuallySelected, selectionGeneration)
                    VALUES ('item-b', 'vault-b', ?, NULL, 'cached', 1, ?)
                    """,
                arguments: [Date(timeIntervalSince1970: 11), UUID().uuidString]
            )

            try db.execute(sql: "DELETE FROM items WHERE id = 'item-a'")
        }
        #expect(try database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineItems WHERE itemId = 'item-a'")
        } == 0)
        #expect(try database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineVaults WHERE vaultId = 'vault-a'")
        } == 1)

        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM vaults WHERE id = 'vault-b'")
        }
        let remaining = try database.reader.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineVaults WHERE vaultId = 'vault-b'"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineItems WHERE itemId = 'item-b'"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items WHERE id = 'item-b'")
            )
        }
        #expect(remaining.0 == 0)
        #expect(remaining.1 == 0)
        #expect(remaining.2 == 0)
    }

    private func makeV9Fixture() throws -> (root: URL, databaseURL: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatabaseManagerMigrationV10Tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("app.db")
        var configuration = Configuration()
        configuration.prepareDatabase { db in try db.usePassphrase(passphrase) }
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)

        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE vaults (id TEXT PRIMARY KEY, name TEXT NOT NULL, shareId TEXT NOT NULL);
                CREATE TABLE items (
                    id TEXT PRIMARY KEY,
                    vaultId TEXT NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
                    title TEXT NOT NULL,
                    itemType TEXT NOT NULL,
                    subtitle TEXT NOT NULL DEFAULT '',
                    url TEXT,
                    hasTOTP BOOLEAN NOT NULL DEFAULT 0,
                    state TEXT NOT NULL,
                    createTime DATETIME NOT NULL,
                    modifyTime DATETIME NOT NULL,
                    useCount INTEGER NOT NULL DEFAULT 0,
                    lastUsedAt DATETIME,
                    fieldKeysJSON TEXT NOT NULL DEFAULT '[]'
                );
                CREATE TABLE autoFillDescriptors (
                    id TEXT PRIMARY KEY,
                    vaultID TEXT NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
                    itemID TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                    shareID TEXT NOT NULL,
                    title TEXT NOT NULL,
                    username TEXT NOT NULL,
                    serviceIdentifier TEXT NOT NULL,
                    hasTOTP BOOLEAN NOT NULL,
                    UNIQUE (vaultID, itemID, serviceIdentifier, username)
                );
                CREATE TABLE autoFillAppAssociations (
                    serviceIdentifier TEXT NOT NULL,
                    serviceKind TEXT NOT NULL,
                    descriptorID TEXT NOT NULL REFERENCES autoFillDescriptors(id) ON DELETE CASCADE,
                    serviceDisplayName TEXT,
                    createdAt DATETIME NOT NULL,
                    UNIQUE (serviceKind, serviceIdentifier)
                );
                CREATE INDEX autoFillAppAssociations_service ON autoFillAppAssociations(serviceKind, serviceIdentifier);
                CREATE TABLE sshAuthDecisions (
                    appIdentifier TEXT NOT NULL,
                    keyFingerprint TEXT NOT NULL,
                    expiresAt DATETIME,
                    appTeamID TEXT,
                    PRIMARY KEY (appIdentifier, keyFingerprint)
                );
                CREATE TABLE runAuthDecisions (
                    appIdentifier TEXT NOT NULL,
                    subcommand TEXT NOT NULL,
                    profileSlug TEXT NOT NULL,
                    expiresAt DATETIME,
                    appTeamID TEXT,
                    PRIMARY KEY (appIdentifier, subcommand, profileSlug)
                );
                CREATE TABLE grdb_migrations (identifier TEXT PRIMARY KEY);
                """)
            for version in 1...9 {
                try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: ["v\(version)"])
            }
            for suffix in ["a", "b"] {
                try db.execute(sql: "INSERT INTO vaults (id, name, shareId) VALUES (?, ?, ?)", arguments: ["vault-\(suffix)", "Legacy \(suffix.uppercased())", "share-\(suffix)"])
                try db.execute(sql: """
                    INSERT INTO items (id, vaultId, title, itemType, state, createTime, modifyTime)
                    VALUES (?, ?, ?, 'login', 'Active', ?, ?)
                    """, arguments: ["item-\(suffix)", "vault-\(suffix)", "Legacy \(suffix.uppercased())", Date(timeIntervalSince1970: 1), Date(timeIntervalSince1970: 2)])
                try db.execute(sql: """
                    INSERT INTO autoFillDescriptors (id, vaultID, itemID, shareID, title, username, serviceIdentifier, hasTOTP)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 0)
                    """, arguments: ["descriptor-\(suffix)", "vault-\(suffix)", "item-\(suffix)", "share-\(suffix)", "Legacy \(suffix.uppercased())", "\(suffix)@example.com", "\(suffix).example.com"])
                try db.execute(sql: """
                    INSERT INTO autoFillAppAssociations (serviceIdentifier, serviceKind, descriptorID, serviceDisplayName, createdAt)
                    VALUES (?, 'domain', ?, ?, ?)
                    """, arguments: ["\(suffix).example.com", "descriptor-\(suffix)", "Legacy App \(suffix.uppercased())", Date(timeIntervalSince1970: 3)])
            }
        }
        return (root, databaseURL)
    }
}
