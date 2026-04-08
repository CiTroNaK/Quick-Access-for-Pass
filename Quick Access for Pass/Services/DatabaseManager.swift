import Foundation
import GRDB

nonisolated final class DatabaseManager: Sendable {
    let writer: any DatabaseWriter
    let reader: any DatabaseReader

    /// Production initializer: opens encrypted database at the given path.
    init(path: String, passphrase: Data) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.usePassphrase(passphrase)
        }
        let pool = try DatabasePool(path: path, configuration: config)
        self.writer = pool
        self.reader = pool
        try Self.migrate(pool)
    }

    /// Test initializer: in-memory database.
    init(inMemory: Bool, passphrase: Data) throws {
        precondition(inMemory)
        var config = Configuration()
        config.prepareDatabase { db in
            try db.usePassphrase(passphrase)
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
        // swiftlint:enable identifier_name
    }

    // MARK: - Utility

    func clearAll() throws {
        try writer.write { db in
            try PassItem.deleteAll(db)
            try PassVault.deleteAll(db)
        }
    }
}
