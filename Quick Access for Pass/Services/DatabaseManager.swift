import Foundation
import GRDB

nonisolated final class DatabaseManager: Sendable {
    let writer: any DatabaseWriter
    let reader: any DatabaseReader
    let offlineReleaseAuthority = OfflineReleaseAuthority()
    let offlineMutationTesting: OfflineMutationTesting?

    /// Production initializer: opens encrypted database at the given path.
    init(path: String, passphrase: Data, offlineMutationTesting: OfflineMutationTesting? = nil) throws {
        self.offlineMutationTesting = offlineMutationTesting
        let databaseURL = URL(fileURLWithPath: path)
        try HardenedDatabaseFiles.prepareDatabaseDirectory(for: databaseURL)
        try HardenedDatabaseFiles.protectDatabaseFiles(at: databaseURL)

        var config = Configuration()
        config.prepareDatabase { db in
            try EncryptedDatabaseConfiguration.prepare(db, passphrase: passphrase)
        }
        let pool = try DatabasePool(path: path, configuration: config)
        self.writer = pool
        self.reader = pool
        try Self.migrate(pool)
        try HardenedDatabaseFiles.protectDatabaseFiles(at: databaseURL)
    }

    /// Test initializer: in-memory database.
    init(inMemory: Bool, passphrase: Data, offlineMutationTesting: OfflineMutationTesting? = nil) throws {
        self.offlineMutationTesting = offlineMutationTesting
        precondition(inMemory)
        var config = Configuration()
        config.prepareDatabase { db in
            try EncryptedDatabaseConfiguration.prepare(db, passphrase: passphrase)
        }
        let queue = try DatabaseQueue(configuration: config)
        self.writer = queue
        self.reader = queue
        try Self.migrate(queue)
    }

    // MARK: - Migrations

    private static func migrate(_ writer: any DatabaseWriter) throws {
        var migrator = DatabaseMigrator()
        registerMigrations(&migrator)
        try migrator.migrate(writer)
    }

    // multi-table migration block
    // swiftlint:disable:next function_body_length
    private static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        // GRDB migration convention uses t for table definitions
        // swiftlint:disable identifier_name
        migrator.registerMigration("v1") { db in
            try db.create(table: "vaults") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
            }

            try db.create(table: "items") { t in
                t.primaryKey("id", .text)
                t.column("vaultId", .text).notNull().references("vaults", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("itemType", .text).notNull()
                t.column("subtitle", .text).notNull().defaults(to: "")
                t.column("url", .text)
                t.column("hasTOTP", .boolean).notNull().defaults(to: false)
                t.column("state", .text).notNull()
                t.column("createTime", .datetime).notNull()
                t.column("modifyTime", .datetime).notNull()
                t.column("useCount", .integer).notNull().defaults(to: 0)
                t.column("lastUsedAt", .datetime)
            }

            try db.create(virtualTable: "items_ft", using: FTS5()) {
                $0.synchronize(withTable: "items")
                $0.tokenizer = .unicode61()
                $0.column("title")
                $0.column("subtitle")
                $0.column("url")
            }

            try db.create(table: "sshAuthDecisions") { t in
                t.column("appIdentifier", .text).notNull()
                t.column("keyFingerprint", .text).notNull()
                t.column("expiresAt", .datetime).notNull()
                t.primaryKey(["appIdentifier", "keyFingerprint"])
            }

            try db.create(table: "sshBatchModeDecisions") { t in
                t.column("keyFingerprint", .text).notNull()
                t.column("host", .text).notNull()
                t.column("keyName", .text)
                t.column("allowed", .boolean).notNull()
                t.column("createdAt", .datetime).notNull()
                t.primaryKey(["keyFingerprint", "host"])
            }
        }

        migrator.registerMigration("v2") { db in
            try db.create(table: "runProfiles") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("slug", .text).notNull().unique()
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "runProfileEnvMappings") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("profileId", .integer).notNull().references("runProfiles", onDelete: .cascade)
                t.column("envVariable", .text).notNull()
                t.column("secretReference", .text).notNull()
            }

            try db.create(table: "runAuthDecisions") { t in
                t.column("appIdentifier", .text).notNull()
                t.column("subcommand", .text).notNull()
                t.column("profileSlug", .text).notNull()
                t.column("expiresAt", .datetime).notNull()
                t.primaryKey(["appIdentifier", "subcommand", "profileSlug"])
            }
        }

        migrator.registerMigration("v3") { db in
            try db.alter(table: "runProfiles") { t in
                t.add(column: "cacheDuration", .text).notNull().defaults(to: "5 minutes")
            }
        }

        migrator.registerMigration("v4") { db in
            try db.alter(table: "items") { t in
                t.add(column: "fieldKeysJSON", .text).notNull().defaults(to: "[]")
            }
        }

        migrator.registerMigration("v5") { db in
            try db.execute(sql: "DELETE FROM sshAuthDecisions")
            try db.execute(sql: "DELETE FROM sshBatchModeDecisions")
            try db.execute(sql: "DELETE FROM runAuthDecisions")

            try db.alter(table: "sshAuthDecisions") { t in
                t.add(column: "appTeamID", .text)
            }
            try db.alter(table: "sshBatchModeDecisions") { t in
                t.add(column: "appIdentifier", .text)
                t.add(column: "appTeamID", .text)
            }
            try db.alter(table: "runAuthDecisions") { t in
                t.add(column: "appTeamID", .text)
            }
        }

        migrator.registerMigration("v6") { db in
            // sshAuthDecisions: make expiresAt nullable (SQLite requires table rewrite).
            try db.create(table: "sshAuthDecisions_new") { t in
                t.column("appIdentifier", .text).notNull()
                t.column("keyFingerprint", .text).notNull()
                t.column("expiresAt", .datetime)
                t.column("appTeamID", .text)
                t.primaryKey(["appIdentifier", "keyFingerprint"])
            }
            try db.execute(sql: """
                INSERT INTO sshAuthDecisions_new
                    (appIdentifier, keyFingerprint, expiresAt, appTeamID)
                SELECT appIdentifier, keyFingerprint, expiresAt, appTeamID
                FROM sshAuthDecisions
                """)
            try db.drop(table: "sshAuthDecisions")
            try db.rename(table: "sshAuthDecisions_new", to: "sshAuthDecisions")

            // runAuthDecisions: same pattern.
            try db.create(table: "runAuthDecisions_new") { t in
                t.column("appIdentifier", .text).notNull()
                t.column("subcommand", .text).notNull()
                t.column("profileSlug", .text).notNull()
                t.column("expiresAt", .datetime)
                t.column("appTeamID", .text)
                t.primaryKey(["appIdentifier", "subcommand", "profileSlug"])
            }
            try db.execute(sql: """
                INSERT INTO runAuthDecisions_new
                    (appIdentifier, subcommand, profileSlug, expiresAt, appTeamID)
                SELECT appIdentifier, subcommand, profileSlug, expiresAt, appTeamID
                FROM runAuthDecisions
                """)
            try db.drop(table: "runAuthDecisions")
            try db.rename(table: "runAuthDecisions_new", to: "runAuthDecisions")
        }

        migrator.registerMigration("v7") { db in
            try db.alter(table: "vaults") { t in
                t.add(column: "shareId", .text).notNull().defaults(to: "")
            }
            try db.execute(sql: "UPDATE vaults SET shareId = id WHERE shareId = ''")
        }

        migrator.registerMigration("v8") { db in
            try db.create(table: AutoFillCredentialDescriptor.databaseTableName) { t in
                t.column("id", .text).primaryKey()
                t.column("vaultID", .text).notNull().references("vaults", onDelete: .cascade)
                t.column("itemID", .text).notNull().references("items", onDelete: .cascade)
                t.column("shareID", .text).notNull()
                t.column("title", .text).notNull()
                t.column("username", .text).notNull()
                t.column("serviceIdentifier", .text).notNull()
                t.column("hasTOTP", .boolean).notNull()
                t.uniqueKey(["vaultID", "itemID", "serviceIdentifier", "username"])
            }
        }

        migrator.registerMigration("v9") { db in
            try db.create(table: "autoFillAppAssociations") { t in
                t.column("serviceIdentifier", .text).notNull()
                t.column("serviceKind", .text).notNull()
                t.column("descriptorID", .text).notNull()
                    .references(AutoFillCredentialDescriptor.databaseTableName, onDelete: .cascade)
                t.column("serviceDisplayName", .text)
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["serviceKind", "serviceIdentifier"])
            }
            try db.create(index: "autoFillAppAssociations_service", on: "autoFillAppAssociations", columns: ["serviceKind", "serviceIdentifier"])
        }

        migrator.registerMigration("v10") { db in
            try db.create(table: "offlineVaults") { t in
                t.column("vaultId", .text).primaryKey().references("vaults", onDelete: .cascade)
                t.column("enabledAt", .datetime).notNull()
            }
            try db.create(table: "offlineItems") { t in
                t.column("itemId", .text).primaryKey().references("items", onDelete: .cascade)
                t.column("vaultId", .text).notNull().references("vaults", onDelete: .cascade)
                t.column("selectedAt", .datetime).notNull()
                t.column("lastRefreshedAt", .datetime)
                t.column("cacheStatus", .text).notNull()
            }
        }

        migrator.registerMigration("v11") { db in
            try db.execute(sql: "ALTER TABLE offlineItems ADD COLUMN pendingRequestId TEXT")
            try db.execute(sql: "CREATE UNIQUE INDEX offlineItems_identity ON offlineItems(itemId, vaultId)")
            try db.execute(sql: """
                CREATE TABLE offlineSnapshots (
                    vaultId TEXT NOT NULL,
                    itemId TEXT NOT NULL,
                    schemaVersion INTEGER NOT NULL CHECK(schemaVersion BETWEEN 1 AND 255),
                    snapshotRevision TEXT NOT NULL,
                    keyFingerprint BLOB NOT NULL CHECK(typeof(keyFingerprint) = 'blob' AND length(keyFingerprint) = 32),
                    encryptedPayload BLOB NOT NULL CHECK(typeof(encryptedPayload) = 'blob' AND length(encryptedPayload) BETWEEN 28 AND 4194332),
                    PRIMARY KEY(vaultId, itemId),
                    FOREIGN KEY(itemId, vaultId) REFERENCES offlineItems(itemId, vaultId) ON DELETE CASCADE
                )
                """)
        }

        migrator.registerMigration("v12") { db in
            // Permission-only vault rows are deliberately not promoted to whole-vault consent.
            try db.execute(sql: "DELETE FROM offlineVaults")
            try db.execute(sql: """
                ALTER TABLE offlineVaults ADD COLUMN policyGeneration TEXT NOT NULL
                DEFAULT '00000000-0000-0000-0000-000000000000' CHECK(length(policyGeneration) = 36)
                """)
            try db.execute(sql: """
                ALTER TABLE offlineItems ADD COLUMN isManuallySelected INTEGER NOT NULL
                DEFAULT 1 CHECK(isManuallySelected IN (0, 1))
                """)
            try db.execute(sql: """
                ALTER TABLE offlineItems ADD COLUMN selectionGeneration TEXT NOT NULL
                DEFAULT '00000000-0000-0000-0000-000000000000' CHECK(length(selectionGeneration) = 36)
                """)
            try db.execute(sql: """
                CREATE TABLE offlineItemExclusions (
                    itemId TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                    vaultId TEXT NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
                    PRIMARY KEY(itemId, vaultId)
                )
                """)
            let itemIDs = try String.fetchAll(db, sql: "SELECT itemId FROM offlineItems")
            for itemID in itemIDs {
                try db.execute(
                    sql: "UPDATE offlineItems SET selectionGeneration = ? WHERE itemId = ?",
                    arguments: [UUID().uuidString, itemID]
                )
            }
        }
        // swiftlint:enable identifier_name
    }

    // MARK: - Utility

    func clearAll() throws {
        try writeOfflineMutation(submissionScope: .all) { db in
            try PassItem.deleteAll(db)
            try PassVault.deleteAll(db)
            return OfflineMutationUpdate(value: (), manualPromotions: [])
        }
    }

    /// Clears ordinary metadata and cascaded offline selections in one database transaction.
    func clearMetadata() async throws {
        try await writeOfflineMutation(submissionScope: .all) { db in
            try PassItem.deleteAll(db)
            try PassVault.deleteAll(db)
            return OfflineMutationUpdate(value: (), manualPromotions: [])
        }
    }
}
