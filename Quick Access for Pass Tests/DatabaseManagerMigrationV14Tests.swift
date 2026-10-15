import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("DatabaseManager Migration v14")
struct DatabaseManagerMigrationV14Tests {
    private struct LegacyDecision {
        let appIdentifier: String
        let subcommand: String
        let profileSlug: String
        let expiresAt: Date?
        let appTeamID: String?
        let allowed: Bool
    }

    private let passphrase = Data("run-decision-v14-test-key".utf8)

    @Test("v13 upgrade drops only valid exact keys and retains literal rule fields")
    func upgradesV13RunDecisions() throws {
        let fixture = try makeV13Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let database = try DatabaseManager(path: fixture.databaseURL.path, passphrase: passphrase)
        let rows = try persistedRows(database)
        #expect(rows.count == 5)
        let retained = Dictionary(uniqueKeysWithValues: rows.map { ($0.appIdentifier, $0) })
        #expect(retained["broad"]?.matchType == RunAuthorizationMatchType.commandPrefixV1.rawValue)
        #expect(retained["broad"]?.matchValue == "gh pr")
        #expect(retained["broad"]?.commandText == "gh pr")
        #expect(retained["broad"]?.allowed == false)
        #expect(retained["broad"]?.appTeamID == "TEAM-B")
        #expect(retained["broad"]?.expiresAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(retained["malformed"]?.matchValue == "exact-v1:" + String(repeating: "a", count: 63))
        #expect(retained["malformed"]?.profileSlug == "p4")
        #expect(retained["malformed"]?.allowed == true)
        #expect(retained["malformed"]?.expiresAt == nil)
        #expect(retained["upper"]?.matchValue == "exact-v1:" + String(repeating: "A", count: 64))
        #expect(retained["upper"]?.profileSlug == "p5")
        #expect(retained["upper"]?.allowed == true)
        #expect(retained["upper"]?.expiresAt == nil)
        #expect(retained["nul"]?.profileSlug == "p6")
        #expect(retained["nul"]?.allowed == true)
        #expect(retained["nul"]?.expiresAt == nil)
        #expect(retained["unknown-literal"]?.profileSlug == "p7")
        #expect(retained["unknown-literal"]?.allowed == true)
        #expect(retained["unknown-literal"]?.expiresAt == nil)
        #expect(try database.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM runAuthDecisions WHERE matchType = 'exact-argv-v1'") } == 0)
        let nulText = "exact-v1:" + String(repeating: "a", count: 64) + "\0"
        let nulValues = try database.reader.read { db in
            try Row.fetchOne(db, sql: """
                SELECT CAST(matchValue AS BLOB) AS matchValue,
                    CAST(commandText AS BLOB) AS commandText
                FROM runAuthDecisions WHERE appIdentifier = 'nul'
                """)
        }
        #expect((nulValues?["matchValue"] as Data?) == Data(nulText.utf8))
        #expect((nulValues?["commandText"] as Data?) == Data(nulText.utf8))
        let unknownDigest = "exact-v2:" + String(repeating: "b", count: 64)
        #expect(retained["unknown-literal"]?.matchValue == unknownDigest)
        #expect(retained.values.allSatisfy { $0.commandText == $0.matchValue })
        let nulRetainedCount = try database.reader.read {
            try Int.fetchOne($0, sql: """
                SELECT COUNT(*) FROM runAuthDecisions
                WHERE matchValue LIKE 'exact-v1:%'
                    AND length(CAST(matchValue AS BLOB)) = 73
                """)
        }
        #expect(nulRetainedCount == 1)
        let migration = try database.reader.read {
            try String.fetchOne($0, sql: "SELECT identifier FROM grdb_migrations WHERE identifier = 'v14'")
        }
        #expect(migration == "v14")
    }

    @Test("v14 constraints reject missing values, invalid outcomes and malformed exact digest byte lengths")
    func constraintsRejectInvalidRecords() throws {
        let database = try DatabaseManager(inMemory: true, passphrase: passphrase)
        try database.writer.write { db in
            let valid = """
                INSERT INTO runAuthDecisions
                    (matchType, matchValue, commandText, appIdentifier, profileSlug, allowed)
                VALUES (?, ?, ?, ?, ?, ?)
                """
            let exactInsert = """
                INSERT INTO runAuthDecisions
                    (matchType, matchValue, commandText, appIdentifier, profileSlug, allowed)
                VALUES ('exact-argv-v1', ?, 'x', 'app', 'p', 1)
                """
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: """
                    INSERT INTO runAuthDecisions (matchType, matchValue, appIdentifier, profileSlug, allowed)
                    VALUES ('command-prefix-v1', 'x', 'app', 'p', 1)
                    """)
            }
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: """
                    INSERT INTO runAuthDecisions
                        (matchType, matchValue, commandText, appIdentifier, profileSlug)
                    VALUES ('command-prefix-v1', 'x', 'x', 'app', 'p')
                    """)
            }
            let nulInsert = """
                INSERT INTO runAuthDecisions
                    (matchType, matchValue, commandText, appIdentifier, profileSlug, allowed)
                VALUES ('exact-argv-v1', ? || char(0), 'x', 'app', 'p', 1)
                """
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: """
                    INSERT INTO runAuthDecisions
                        (matchType, matchValue, commandText, appIdentifier, profileSlug, allowed)
                    VALUES ('command-prefix-v1', 'x', 'x', 'app', 'p', 2)
                    """)
            }
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: exactInsert, arguments: [String(repeating: "a", count: 63)])
            }
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: nulInsert, arguments: [String(repeating: "a", count: 64)])
            }
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: exactInsert, arguments: [String(repeating: "A", count: 64)])
            }
            try db.execute(sql: valid, arguments: ["future-v9", "unknown", "text", "future-app", "p", true])
            #expect(try RunAuthDecision.fetchAll(db).count == 1)
        }
    }

    @Test("encrypted on-disk reopen preserves text, typed identity, outcome, expiry and IDs")
    func onDiskReopenPreservesDecision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("run-v14-reopen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("app.db").path
        let passphrase = Data("synthetic-v14-reopen-key".utf8)
        let command = ["git", "pull", "--ff-only"]
        let scope = try #require(RunAuthorizationScope.exact(command: command))
        let expiration = Date().addingTimeInterval(600)
        var manager: DatabaseManager? = try DatabaseManager(path: path, passphrase: passphrase)
        try manager?.saveRunDecision(
            appIdentifier: "TEAM.com.example.Terminal", scope: scope, profileSlug: "work",
            expiresAt: expiration, allowed: false, appTeamID: "TEAM"
        )
        let originalRows = try manager?.allRunAuthDecisions() ?? []
        let original = try #require(originalRows.first)
        manager = nil

        let reopened = try DatabaseManager(path: path, passphrase: passphrase)
        let storedDecision = try reopened.findValidRunDecision(
            appIdentifier: "TEAM.com.example.Terminal", identity: scope.identity, profileSlug: "work"
        )
        let found = try #require(storedDecision)
        #expect(found.id == original.id)
        #expect(found.matchType == scope.identity.matchType.rawValue)
        #expect(found.matchValue == scope.identity.matchValue)
        #expect(found.commandText == scope.label)
        #expect(found.allowed == false)
        #expect(abs(try #require(found.expiresAt).timeIntervalSince(expiration)) < 1)
        #expect(found.appTeamID == "TEAM")
        #expect(found.profileSlug == "work")
    }

    @Test("migration failure rolls back schema, rows and migration marker; retry succeeds")
    func failureRollsBackAndRetrySucceeds() throws {
        let fixture = try makeV13Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let setup = try makeQueue(at: fixture.databaseURL)
        try setup.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_v14_marker BEFORE INSERT ON grdb_migrations
                WHEN NEW.identifier = 'v14'
                BEGIN
                    SELECT RAISE(ABORT, 'synthetic v14 marker failure');
                END
                """)
        }
        #expect(throws: (any Error).self) {
            _ = try DatabaseManager(path: fixture.databaseURL.path, passphrase: passphrase)
        }
        try setup.read { db in
            let oldTable = try String.fetchOne(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'runAuthDecisions'")
            let temporaryTable = try String.fetchOne(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'runAuthDecisions_v14'")
            let rowCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM runAuthDecisions")
            let migration = try String.fetchOne(db, sql: "SELECT identifier FROM grdb_migrations WHERE identifier = 'v14'")
            let oldColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(runAuthDecisions)").compactMap { $0["name"] as String? }
            let oldBroad = try Row.fetchOne(db, sql: """
                SELECT subcommand, profileSlug, expiresAt, appTeamID, allowed
                FROM runAuthDecisions WHERE appIdentifier = 'broad'
                """)
            #expect(oldTable == "runAuthDecisions")
            #expect(temporaryTable == nil)
            #expect(rowCount == 7)
            #expect(oldColumns == ["appIdentifier", "subcommand", "profileSlug", "expiresAt", "appTeamID", "allowed"])
            #expect((oldBroad?["subcommand"] as String?) == "gh pr")
            #expect((oldBroad?["profileSlug"] as String?) == "p3")
            #expect((oldBroad?["expiresAt"] as Date?) == Date(timeIntervalSince1970: 1_700_000_000))
            #expect((oldBroad?["appTeamID"] as String?) == "TEAM-B")
            #expect((oldBroad?["allowed"] as Int?) == 0)
            #expect(migration == nil)
        }
        try setup.write { try $0.execute(sql: "DROP TRIGGER fail_v14_marker") }
        let database = try DatabaseManager(path: fixture.databaseURL.path, passphrase: passphrase)
        #expect(try persistedRows(database).count == 5)
    }

    private func persistedRows(_ database: DatabaseManager) throws -> [RunAuthDecision] {
        try database.reader.read { try RunAuthDecision.fetchAll($0) }
    }

    private func makeV13Fixture() throws -> (root: URL, databaseURL: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("run-v14-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("app.db")
        let queue = try makeQueue(at: databaseURL)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE runAuthDecisions (
                    appIdentifier TEXT NOT NULL, subcommand TEXT NOT NULL, profileSlug TEXT NOT NULL,
                    expiresAt DATETIME, appTeamID TEXT, allowed INTEGER NOT NULL
                );
                -- Empty offline tables already exist at v13; no offline content migration fixture is needed.
                CREATE TABLE offlineItems (itemId TEXT PRIMARY KEY, vaultId TEXT NOT NULL);
                CREATE TABLE offlineSnapshots (vaultId TEXT NOT NULL, itemId TEXT NOT NULL);
                CREATE TABLE grdb_migrations (identifier TEXT PRIMARY KEY);
                """)
            for version in 1...13 {
                try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: ["v\(version)"])
            }
            let exact = "exact-v1:" + String(repeating: "a", count: 64)
            let rows = [
                LegacyDecision(appIdentifier: "valid-allow", subcommand: exact, profileSlug: "p1", expiresAt: nil, appTeamID: "TEAM-A", allowed: true),
                LegacyDecision(
                    appIdentifier: "valid-deny", subcommand: "exact-v1:" + String(repeating: "b", count: 64),
                    profileSlug: "p2", expiresAt: Date(timeIntervalSince1970: 1_700_000_000),
                    appTeamID: nil, allowed: false
                ),
                LegacyDecision(
                    appIdentifier: "broad", subcommand: "gh pr", profileSlug: "p3",
                    expiresAt: Date(timeIntervalSince1970: 1_700_000_000), appTeamID: "TEAM-B", allowed: false
                ),
                LegacyDecision(
                    appIdentifier: "malformed", subcommand: "exact-v1:" + String(repeating: "a", count: 63),
                    profileSlug: "p4", expiresAt: nil, appTeamID: nil, allowed: true
                ),
                LegacyDecision(
                    appIdentifier: "upper", subcommand: "exact-v1:" + String(repeating: "A", count: 64),
                    profileSlug: "p5", expiresAt: nil, appTeamID: nil, allowed: true
                ),
                LegacyDecision(
                    appIdentifier: "unknown-literal", subcommand: "exact-v2:" + String(repeating: "b", count: 64),
                    profileSlug: "p7", expiresAt: nil, appTeamID: nil, allowed: true
                )
            ]
            for row in rows {
                try db.execute(
                    sql: "INSERT INTO runAuthDecisions VALUES (?, ?, ?, ?, ?, ?)",
                    arguments: [row.appIdentifier, row.subcommand, row.profileSlug, row.expiresAt, row.appTeamID, row.allowed]
                )
            }
            try db.execute(
                sql: "INSERT INTO runAuthDecisions VALUES (?, ? || char(0), ?, ?, ?, ?)",
                arguments: ["nul", "exact-v1:" + String(repeating: "a", count: 64), "p6", nil, nil, true]
            )
        }
        return (root, databaseURL)
    }

    private func makeQueue(at url: URL) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.prepareDatabase { try $0.usePassphrase(passphrase) }
        return try DatabaseQueue(path: url.path, configuration: configuration)
    }
}
