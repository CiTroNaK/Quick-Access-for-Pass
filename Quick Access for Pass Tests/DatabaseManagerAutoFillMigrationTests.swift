import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("DatabaseManager AutoFill migration")
struct DatabaseManagerAutoFillMigrationTests {
    private let passphrase = Data("autofill-migration-test".utf8)

    @Test("migrations add only non-secret metadata and preserve v7 data")
    func migrationPreservesExistingData() throws {
        let fixture = try makeV7Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let database = try DatabaseManager(path: fixture.databaseURL.path, passphrase: passphrase)
        let columns = try database.reader.read { db in
            try db.columns(in: AutoFillCredentialDescriptor.databaseTableName).map(\.name)
        }
        let legacyValue = try database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM legacyMarker")
        }
        let sshDecision = try database.findValidDecision(
            appIdentifier: "com.test.ssh",
            keyFingerprint: "SHA256:legacy"
        )
        let runDecision = try database.findValidRunDecision(
            appIdentifier: "com.test.run",
            subcommand: "git fetch",
            profileSlug: "work"
        )

        #expect(Set(columns) == [
            "id", "vaultID", "itemID", "shareID", "title", "username",
            "serviceIdentifier", "hasTOTP"
        ])
        #expect(!columns.contains { column in
            let normalized = column.lowercased()
            return normalized.contains("password")
                || normalized.contains("seed")
                || normalized.contains("uri")
                || normalized.contains("code")
        })
        #expect(legacyValue == "preserved")
        #expect(sshDecision?.allowed == true)
        #expect(runDecision?.allowed == true)
    }

    @Test("v9 app associations constrain descriptor references and service identity")
    func appAssociationSchema() throws {
        let database = try DatabaseManager(inMemory: true, passphrase: passphrase)
        let columns = try database.reader.read { db in
            try db.columns(in: "autoFillAppAssociations").map(\.name)
        }
        let foreignKeys = try database.reader.read { db in
            try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(autoFillAppAssociations)")
        }
        let indexes = try database.reader.read { db in
            try Row.fetchAll(db, sql: "PRAGMA index_list(autoFillAppAssociations)")
        }

        #expect(Set(columns) == [
            "serviceIdentifier", "serviceKind", "descriptorID", "serviceDisplayName", "createdAt"
        ])
        #expect(foreignKeys.contains { ($0["table"] as String) == "autoFillDescriptors" && ($0["on_delete"] as String) == "CASCADE" })
        #expect(indexes.contains { ($0["name"] as String).contains("service") })
    }

    @Test("schema enforces one opaque descriptor per identity key")
    func uniqueIdentityKey() throws {
        let database = try DatabaseManager(inMemory: true, passphrase: passphrase)
        try database.upsertVaults([PassVault(id: "vault", name: "Personal", shareId: "share")])
        try database.upsertItems([makeItem()])
        let first = AutoFillCredentialDescriptor(
            id: UUID(),
            vaultID: "vault",
            itemID: "item",
            shareID: "share",
            title: "Example",
            username: "person@example.com",
            serviceIdentifier: "example.com",
            hasTOTP: true
        )
        let duplicateKey = AutoFillCredentialDescriptor(
            id: UUID(),
            vaultID: first.vaultID,
            itemID: first.itemID,
            shareID: first.shareID,
            title: "Other title",
            username: first.username,
            serviceIdentifier: first.serviceIdentifier,
            hasTOTP: false
        )
        try database.writer.write { db in try first.insert(db) }

        #expect(throws: DatabaseError.self) {
            try database.writer.write { db in try duplicateKey.insert(db) }
        }
    }

    @Test("metadata sync preserves opaque IDs and rotates them only with the identity key")
    func stableOpaqueIdentifiers() throws {
        let database = try DatabaseManager(inMemory: true, passphrase: passphrase)
        let vault = PassVault(id: "vault", name: "Personal", shareId: "share")
        let item = makeItem(username: "person@example.com")
        let firstInput = AutoFillDescriptorInput(
            vaultID: "vault",
            itemID: "item",
            shareID: "share",
            title: "Example",
            username: "person@example.com",
            serviceIdentifier: "example.com",
            hasTOTP: true
        )

        let first = try database.syncMetadata(vaults: [vault], items: [item], descriptors: [firstInput])
        let firstID = try #require(first.first?.id)
        let updatedInput = AutoFillDescriptorInput(
            vaultID: "vault",
            itemID: "item",
            shareID: "new-share",
            title: "Renamed",
            username: "person@example.com",
            serviceIdentifier: "example.com",
            hasTOTP: false
        )
        let second = try database.syncMetadata(
            vaults: [PassVault(id: "vault", name: "Personal", shareId: "new-share")],
            items: [item],
            descriptors: [updatedInput]
        )

        #expect(second.first?.id == firstID)
        #expect(second.first?.title == "Renamed")
        #expect(second.first?.hasTOTP == false)

        let changedIdentity = AutoFillDescriptorInput(
            vaultID: "vault",
            itemID: "item",
            shareID: "new-share",
            title: "Renamed",
            username: "other@example.com",
            serviceIdentifier: "example.com",
            hasTOTP: false
        )
        let third = try database.syncMetadata(
            vaults: [PassVault(id: "vault", name: "Personal", shareId: "new-share")],
            items: [makeItem(username: "other@example.com")],
            descriptors: [changedIdentity]
        )

        #expect(third.count == 1)
        #expect(third.first?.id != firstID)
    }

    @Test("item and descriptor writes roll back together")
    func transactionRollback() throws {
        enum InjectedFailure: Error { case descriptorWrite }

        let database = try DatabaseManager(inMemory: true, passphrase: passphrase)
        let originalVault = PassVault(id: "vault", name: "Personal", shareId: "share")
        let originalItem = makeItem(title: "Original")
        let originalInput = makeInput(title: "Original")
        let originalDescriptors = try database.syncMetadata(
            vaults: [originalVault],
            items: [originalItem],
            descriptors: [originalInput]
        )

        #expect(throws: InjectedFailure.descriptorWrite) {
            try database.syncMetadata(
                vaults: [originalVault],
                items: [self.makeItem(title: "Changed")],
                descriptors: [self.makeInput(title: "Changed")],
                beforeDescriptorWrite: { throw InjectedFailure.descriptorWrite }
            )
        }

        #expect(try database.allActiveItems().first?.title == "Original")
        #expect(try database.allAutoFillDescriptors() == originalDescriptors)
    }

    @Test("descriptor persistence contains no transient secret values")
    func persistedMetadataContainsNoSecrets() throws {
        let database = try DatabaseManager(inMemory: true, passphrase: passphrase)
        _ = try database.syncMetadata(
            vaults: [PassVault(id: "vault", name: "Personal", shareId: "share")],
            items: [makeItem()],
            descriptors: [makeInput()]
        )

        let persisted = String(
            decoding: try JSONEncoder().encode(database.allAutoFillDescriptors()),
            as: UTF8.self
        )
        #expect(!persisted.contains("password-secret"))
        #expect(!persisted.contains("totp-seed-secret"))
        #expect(!persisted.contains("123456"))
    }

    private func makeItem(
        title: String = "Example",
        username: String = "person@example.com"
    ) -> PassItem {
        PassItem(
            id: "item",
            vaultId: "vault",
            title: title,
            itemType: .login,
            subtitle: username,
            url: "https://only-first.example",
            hasTOTP: true,
            state: "Active",
            createTime: Date(timeIntervalSince1970: 1),
            modifyTime: Date(timeIntervalSince1970: 2),
            useCount: 0,
            lastUsedAt: nil
        )
    }

    private func makeInput(title: String = "Example") -> AutoFillDescriptorInput {
        AutoFillDescriptorInput(
            vaultID: "vault",
            itemID: "item",
            shareID: "share",
            title: title,
            username: "person@example.com",
            serviceIdentifier: "example.com",
            hasTOTP: true
        )
    }

    private func makeV7Fixture() throws -> (root: URL, databaseURL: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatabaseManagerAutoFillMigrationTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("app.db")
        var configuration = Configuration()
        configuration.prepareDatabase { db in try db.usePassphrase(passphrase) }
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        try queue.write { db in
            try db.create(table: "vaults") { table in
                table.column("id", .text).primaryKey()
                table.column("name", .text).notNull()
                table.column("shareId", .text).notNull()
            }
            try db.create(table: "items") { table in
                table.column("id", .text).primaryKey()
                table.column("vaultId", .text).notNull()
            }
            try db.create(table: "sshAuthDecisions") { table in
                table.column("appIdentifier", .text).notNull()
                table.column("keyFingerprint", .text).notNull()
                table.column("expiresAt", .datetime)
                table.column("appTeamID", .text)
                table.primaryKey(["appIdentifier", "keyFingerprint"])
            }
            try db.create(table: "runAuthDecisions") { table in
                table.column("appIdentifier", .text).notNull()
                table.column("subcommand", .text).notNull()
                table.column("profileSlug", .text).notNull()
                table.column("expiresAt", .datetime)
                table.column("appTeamID", .text)
                table.primaryKey(["appIdentifier", "subcommand", "profileSlug"])
            }
            try db.create(table: "legacyMarker") { $0.column("value", .text).notNull() }
            try db.execute(sql: "INSERT INTO legacyMarker (value) VALUES ('preserved')")
            try db.execute(
                sql: """
                INSERT INTO sshAuthDecisions
                    (appIdentifier, keyFingerprint, expiresAt, appTeamID)
                VALUES ('com.test.ssh', 'SHA256:legacy', NULL, NULL)
                """
            )
            try db.execute(
                sql: """
                INSERT INTO runAuthDecisions
                    (appIdentifier, subcommand, profileSlug, expiresAt, appTeamID)
                VALUES ('com.test.run', 'git fetch', 'work', NULL, NULL)
                """
            )
            try db.create(table: "grdb_migrations") { $0.column("identifier", .text).primaryKey() }
            for version in 1...7 {
                try db.execute(
                    sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                    arguments: ["v\(version)"]
                )
            }
        }
        return (root, databaseURL)
    }
}
