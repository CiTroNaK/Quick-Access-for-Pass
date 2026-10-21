import Foundation
import GRDB
import Security
import Synchronization
import Testing
@testable import Quick_Access_for_Pass

@Suite("AutoFill descriptor store")
struct AutoFillDescriptorStoreTests {
    private let passphrase = Data("descriptor-store-passphrase".utf8)

    @Test("opens off main actor and reads through a read-only non-migrating connection")
    @MainActor
    func readsOffMainActorWithoutMigrating() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let observations = Mutex<[Bool]>([])
        let keychain = KeychainService(
            serviceName: "test",
            accessGroup: AutoFillConstants.keychainAccessGroup,
            backend: .init(
                retrieve: { query in
                    observations.withLock { $0.append(Thread.isMainThread) }
                    return .success(self.passphrase)
                },
                add: { _ in .success(()) },
                update: { _ in .success(()) },
                delete: { _ in .success(()) }
            )
        )
        let store = AutoFillDescriptorStore(
            databaseURL: fixture.databaseURL,
            keychainService: keychain,
            didOpenDatabase: {
                observations.withLock { $0.append(Thread.isMainThread) }
            }
        )

        let descriptor = try await store.descriptor(id: fixture.descriptor.id)

        #expect(descriptor == fixture.descriptor)
        #expect(observations.withLock { $0 } == [false, false])
        #expect(try tableNames(at: fixture.databaseURL) == fixture.tableNamesBefore)
    }

    @Test("store exposes descriptor lookup only and does not write other metadata")
    func cannotWriteOtherMetadata() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = try databaseSnapshot(at: fixture.databaseURL)
        let keychain = fakeKeychain(result: .success(passphrase))
        let store = AutoFillDescriptorStore(databaseURL: fixture.databaseURL, keychainService: keychain)

        _ = try await store.descriptor(id: fixture.descriptor.id)
        let missing = try await store.descriptor(id: UUID())

        #expect(missing == nil)
        #expect(try databaseSnapshot(at: fixture.databaseURL) == before)
        #expect(try metadataValue(at: fixture.databaseURL) == "preserve-me")
    }

    @Test("site candidates preserve exact service tiers without parent inference")
    func siteCandidatesUseExactOrderedHosts() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var configuration = Configuration()
        configuration.prepareDatabase { db in try db.usePassphrase(passphrase) }
        let writer = try DatabaseQueue(path: fixture.databaseURL.path, configuration: configuration)
        let parent = AutoFillCredentialDescriptor(
            id: UUID(), vaultID: "vault", itemID: "parent", shareID: "share",
            title: "Parent", username: "parent@example.com", serviceIdentifier: "example.com", hasTOTP: false
        )
        try await writer.write { db in
            try parent.insert(db)
            for index in 0...20 {
                try AutoFillCredentialDescriptor(
                    id: UUID(), vaultID: "vault", itemID: "git-\(index)", shareID: "share",
                    title: "Git \(index)", username: "git\(index)@example.com",
                    serviceIdentifier: "git.example.com", hasTOTP: false
                ).insert(db)
            }
        }
        let store = AutoFillDescriptorStore(
            databaseURL: fixture.databaseURL,
            keychainService: fakeKeychain(result: .success(passphrase))
        )
        let login = try AutoFillServiceIdentifier(kind: .domain, identifier: "login.example.com", displayName: nil)
        let parentService = try AutoFillServiceIdentifier(kind: .url, identifier: "https://example.com/path", displayName: nil)
        let query = AutoFillCandidateQuery.site(
            requestID: UUID(), services: [login, parentService], kind: .password,
            deadlineUptimeNanoseconds: 1
        )

        let candidates = try await store.candidates(for: query)

        #expect(candidates.map(\.descriptorID) == [fixture.descriptor.id, parent.id])
        #expect(candidates.map(\.matchTier) == [0, 1])
        #expect(try await store.candidates(for: .global(
            requestID: UUID(), search: "Git", kind: .password, deadlineUptimeNanoseconds: 1
        )).count == 20)
    }

}

extension AutoFillDescriptorStoreTests {
    @Test("global candidates collapse hosts without merging distinct logins", arguments: [AutoFillValueKind.password, .oneTimeCode])
    func globalCandidatesDeduplicateLogins(kind: AutoFillValueKind) async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var configuration = Configuration()
        configuration.prepareDatabase { db in try db.usePassphrase(passphrase) }
        let writer = try DatabaseQueue(path: fixture.databaseURL.path, configuration: configuration)
        try await writer.write { db in
            // More than the result limit: descriptors must not crowd out other logins.
            for index in 0..<24 {
                try AutoFillCredentialDescriptor(
                    id: UUID(), vaultID: "vault", itemID: "item", shareID: "share",
                    title: "Example", username: "person@example.com",
                    serviceIdentifier: "host-\(index).example.com", hasTOTP: true
                ).insert(db)
            }
            for (vault, item, username) in [
                ("vault", "other-item", "person@example.com"),
                ("other-vault", "item", "person@example.com"),
                ("vault", "item", "other@example.com")
            ] {
                try AutoFillCredentialDescriptor(
                    id: UUID(), vaultID: vault, itemID: item, shareID: "share",
                    title: "Example", username: username,
                    serviceIdentifier: "login.example.com", hasTOTP: true
                ).insert(db)
            }
        }
        let store = AutoFillDescriptorStore(
            databaseURL: fixture.databaseURL,
            keychainService: fakeKeychain(result: .success(passphrase))
        )

        let query = AutoFillCandidateQuery.global(
            requestID: UUID(), search: "Example", kind: kind, deadlineUptimeNanoseconds: 1
        )
        let candidates = try await store.candidates(for: query)
        #expect(candidates.count == 4)
        #expect(candidates.allSatisfy { $0.kind == kind && $0.matchTier == 0 })
        var identities = Set<[String]>()
        for candidate in candidates {
            let descriptor = try #require(try await store.descriptor(id: candidate.descriptorID))
            identities.insert([descriptor.vaultID, descriptor.itemID, descriptor.username])
        }
        #expect(identities == Set([
            ["vault", "item", "person@example.com"],
            ["vault", "other-item", "person@example.com"],
            ["other-vault", "item", "person@example.com"],
            ["vault", "item", "other@example.com"]
        ]))
        #expect(try await store.candidates(for: query) == candidates)
    }

    @Test("site candidates collapse hosts and retain the earliest matching descriptor", arguments: [AutoFillValueKind.password, .oneTimeCode])
    func siteCandidatesDeduplicateLogins(kind: AutoFillValueKind) async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var configuration = Configuration()
        configuration.prepareDatabase { db in try db.usePassphrase(passphrase) }
        let writer = try DatabaseQueue(path: fixture.databaseURL.path, configuration: configuration)
        let alternate = AutoFillCredentialDescriptor(
            id: UUID(), vaultID: "vault", itemID: "item", shareID: "share",
            title: "Example", username: "person@example.com",
            serviceIdentifier: "alternate.example.com", hasTOTP: true
        )
        try await writer.write { db in try alternate.insert(db) }
        let store = AutoFillDescriptorStore(
            databaseURL: fixture.databaseURL,
            keychainService: fakeKeychain(result: .success(passphrase))
        )
        let login = try AutoFillServiceIdentifier(kind: .domain, identifier: "login.example.com", displayName: nil)
        let other = try AutoFillServiceIdentifier(kind: .url, identifier: "https://alternate.example.com/path", displayName: nil)

        for (services, expectedID) in [([login, other], fixture.descriptor.id), ([other, login], alternate.id)] {
            let candidates = try await store.candidates(for: .site(
                requestID: UUID(), services: services, kind: kind, deadlineUptimeNanoseconds: 1
            ))
            #expect(candidates.map(\.descriptorID) == [expectedID])
            #expect(candidates.map(\.matchTier) == [0])
        }
    }

    @Test("global candidate limit counts logins rather than host descriptors")
    func globalLimitCountsLogins() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var configuration = Configuration()
        configuration.prepareDatabase { db in try db.usePassphrase(passphrase) }
        let writer = try DatabaseQueue(path: fixture.databaseURL.path, configuration: configuration)
        try await writer.write { db in
            for index in 0..<21 {
                for host in 0..<3 {
                    try AutoFillCredentialDescriptor(
                        id: UUID(), vaultID: "vault", itemID: "limit-\(index)", shareID: "share",
                        title: String(format: "Limit %02d", index), username: "person@example.com",
                        serviceIdentifier: "host-\(host).example.com", hasTOTP: false
                    ).insert(db)
                }
            }
        }
        let store = AutoFillDescriptorStore(
            databaseURL: fixture.databaseURL,
            keychainService: fakeKeychain(result: .success(passphrase))
        )
        let candidates = try await store.candidates(for: .global(
            requestID: UUID(), search: "Limit", kind: .password, deadlineUptimeNanoseconds: 1
        ))
        #expect(candidates.map(\.title) == (0..<20).map { String(format: "Limit %02d", $0) })
        #expect(try await store.candidates(for: .global(
            requestID: UUID(), search: "Limit", kind: .oneTimeCode, deadlineUptimeNanoseconds: 1
        )).isEmpty)
    }

    @Test("app associations skip duplicate hosts without hiding later logins")
    func appAssociationsDeduplicateBeforeLimiting() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var configuration = Configuration()
        configuration.prepareDatabase { db in try db.usePassphrase(passphrase) }
        let writer = try DatabaseQueue(path: fixture.databaseURL.path, configuration: configuration)
        let other = AutoFillCredentialDescriptor(
            id: UUID(), vaultID: "vault", itemID: "other", shareID: "share",
            title: "ZZ Other", username: "person@example.com",
            serviceIdentifier: "other.example.com", hasTOTP: false
        )
        try await writer.write { db in
            try db.create(table: "autoFillAppAssociations") { table in
                table.column("descriptorID", .text).notNull()
                table.column("serviceKind", .text).notNull()
                table.column("serviceIdentifier", .text).notNull()
            }
            for index in 0..<24 {
                let descriptor = AutoFillCredentialDescriptor(
                    id: UUID(), vaultID: "vault", itemID: "item", shareID: "share",
                    title: "Example", username: "person@example.com",
                    serviceIdentifier: "host-\(index).example.com", hasTOTP: true
                )
                try descriptor.insert(db)
                try db.execute(
                    sql: "INSERT INTO autoFillAppAssociations VALUES (?, 'app', 'com.example.native')",
                    arguments: [descriptor.id]
                )
            }
            try other.insert(db)
            try db.execute(
                sql: "INSERT INTO autoFillAppAssociations VALUES (?, 'app', 'com.example.native')",
                arguments: [other.id]
            )
        }
        let store = AutoFillDescriptorStore(
            databaseURL: fixture.databaseURL,
            keychainService: fakeKeychain(result: .success(passphrase))
        )
        let login = try AutoFillServiceIdentifier(kind: .domain, identifier: "login.example.com", displayName: nil)
        let app = try AutoFillServiceIdentifier(kind: .app, identifier: "com.example.native", displayName: nil)
        let candidates = try await store.candidates(for: .site(
            requestID: UUID(), services: [login, app], kind: .password, deadlineUptimeNanoseconds: 1
        ))
        #expect(candidates.map(\.descriptorID) == [fixture.descriptor.id, other.id])
        #expect(candidates.map(\.matchTier) == [0, 1])
    }
}

extension AutoFillDescriptorStoreTests {
    @Test("long-lived read-only connection observes committed host updates")
    func observesHostUpdates() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = AutoFillDescriptorStore(
            databaseURL: fixture.databaseURL,
            keychainService: fakeKeychain(result: .success(passphrase))
        )
        _ = try await store.descriptor(id: fixture.descriptor.id)

        var configuration = Configuration()
        configuration.prepareDatabase { db in try db.usePassphrase(passphrase) }
        let writer = try DatabaseQueue(path: fixture.databaseURL.path, configuration: configuration)
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE autoFillDescriptors SET title = ? WHERE id = ?",
                arguments: ["Updated", fixture.descriptor.id]
            )
        }

        let updated = try await store.descriptor(id: fixture.descriptor.id)
        #expect(updated?.title == "Updated")
    }

    @Test("host descriptor lookup opens the migrated descriptor schema")
    func readsMigratedHostSchema() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoFillDescriptorStoreMigratedSchemaTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("app.db")
        let database = try DatabaseManager(path: databaseURL.path, passphrase: passphrase)
        let item = PassItem(
            id: "item",
            vaultId: "vault",
            title: "Example",
            itemType: .login,
            subtitle: "person@example.com",
            url: "https://example.com",
            hasTOTP: true,
            state: "Active",
            createTime: Date(timeIntervalSince1970: 1),
            modifyTime: Date(timeIntervalSince1970: 2),
            useCount: 0,
            lastUsedAt: nil
        )
        let descriptors = try database.syncMetadata(
            vaults: [PassVault(id: "vault", name: "Personal", shareId: "share")],
            items: [item],
            descriptors: [
                AutoFillDescriptorInput(
                    vaultID: "vault",
                    itemID: "item",
                    shareID: "share",
                    title: "Example",
                    username: "person@example.com",
                    serviceIdentifier: "example.com",
                    hasTOTP: true
                )
            ]
        )
        let descriptor = try #require(descriptors.first)
        let store = AutoFillDescriptorStore(
            databaseURL: databaseURL,
            keychainService: fakeKeychain(result: .success(passphrase))
        )

        #expect(try await store.descriptor(id: descriptor.id) == descriptor)
    }

    @Test("v9 app association supplies an exact app candidate through the read-only store")
    func readsExactAppAssociationFromMigratedV9Fixture() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoFillDescriptorStoreMigratedV9Tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("app.db")
        let database = try DatabaseManager(path: databaseURL.path, passphrase: passphrase)
        let item = PassItem(
            id: "item", vaultId: "vault", title: "Example", itemType: .login,
            subtitle: "person@example.com", url: "https://example.com", hasTOTP: false,
            state: "Active", createTime: .now, modifyTime: .now, useCount: 0, lastUsedAt: nil
        )
        let descriptors = try database.syncMetadata(
            vaults: [PassVault(id: "vault", name: "Personal", shareId: "share")],
            items: [item],
            descriptors: [
                AutoFillDescriptorInput(
                    vaultID: "vault", itemID: "item", shareID: "share", title: "Example",
                    username: "person@example.com", serviceIdentifier: "example.com", hasTOTP: false
                ),
                AutoFillDescriptorInput(
                    vaultID: "vault", itemID: "item", shareID: "share", title: "App Only",
                    username: "app@example.com", serviceIdentifier: "app.example.com", hasTOTP: false
                )
            ]
        )
        let descriptor = try #require(descriptors.first { $0.serviceIdentifier == "example.com" })
        let appOnlyDescriptor = try #require(descriptors.first { $0.serviceIdentifier == "app.example.com" })
        let service = try AutoFillServiceIdentifier(
            kind: .app, identifier: "com.example.native", displayName: "Example Native"
        )
        let associationStore = AutoFillAppAssociationStore(databaseManager: database)
        try await associationStore.save(service: service, descriptorID: descriptor.id, createdAt: .now)
        try await associationStore.save(service: service, descriptorID: appOnlyDescriptor.id, createdAt: .now)
        let descriptorStore = AutoFillDescriptorStore(
            databaseURL: databaseURL,
            keychainService: fakeKeychain(result: .success(passphrase))
        )

        let domain = try AutoFillServiceIdentifier(
            kind: .domain, identifier: "example.com", displayName: nil
        )
        let candidates = try await descriptorStore.candidates(for: .site(
            requestID: UUID(), services: [domain, service], kind: .password, deadlineUptimeNanoseconds: 1
        ))

        #expect(candidates == [
            AutoFillCandidate(
                descriptorID: descriptor.id,
                title: descriptor.title,
                username: descriptor.username,
                kind: .password,
                matchTier: 0
            ),
            AutoFillCandidate(
                descriptorID: appOnlyDescriptor.id,
                title: appOnlyDescriptor.title,
                username: appOnlyDescriptor.username,
                kind: .password,
                matchTier: 1
            )
        ])
    }

    @Test("locked data-protection Keychain maps to a retryable error")
    func lockedDeviceIsRetryable() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let keychain = fakeKeychain(result: .failure(.retrieveFailed(errSecInteractionNotAllowed)))
        let store = AutoFillDescriptorStore(databaseURL: fixture.databaseURL, keychainService: keychain)

        await #expect(throws: AutoFillDescriptorStore.Error.deviceLocked) {
            try await store.descriptor(id: fixture.descriptor.id)
        }
    }

    @Test("missing host passphrase never opens the encrypted database")
    func missingPassphraseFailsClosed() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let didOpen = Mutex(false)
        let store = AutoFillDescriptorStore(
            databaseURL: fixture.databaseURL,
            keychainService: fakeKeychain(result: .success(nil)),
            didOpenDatabase: { didOpen.withLock { $0 = true } }
        )

        await #expect(throws: AutoFillDescriptorStore.Error.passphraseMissing) {
            try await store.descriptor(id: fixture.descriptor.id)
        }
        #expect(didOpen.withLock { $0 } == false)
    }

    private func fakeKeychain(
        result: Result<Data?, KeychainError>
    ) -> KeychainService {
        KeychainService(
            serviceName: "test",
            accessGroup: AutoFillConstants.keychainAccessGroup,
            backend: .init(
                retrieve: { _ in result },
                add: { _ in .success(()) },
                update: { _ in .success(()) },
                delete: { _ in .success(()) }
            )
        )
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoFillDescriptorStoreTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("app.db")
        var configuration = Configuration()
        configuration.prepareDatabase { db in try db.usePassphrase(passphrase) }
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        let descriptor = AutoFillCredentialDescriptor(
            id: UUID(),
            vaultID: "vault",
            itemID: "item",
            shareID: "share",
            title: "Example",
            username: "person@example.com",
            serviceIdentifier: "login.example.com",
            hasTOTP: true
        )
        try queue.write { db in
            try db.create(table: "autoFillDescriptors") { table in
                table.column("id", .text).primaryKey()
                table.column("vaultID", .text).notNull()
                table.column("itemID", .text).notNull()
                table.column("shareID", .text).notNull()
                table.column("title", .text).notNull()
                table.column("username", .text).notNull()
                table.column("serviceIdentifier", .text).notNull()
                table.column("hasTOTP", .boolean).notNull()
            }
            try db.create(table: "existingMetadata") { table in
                table.column("value", .text).notNull()
            }
            try descriptor.insert(db)
            try db.execute(sql: "INSERT INTO existingMetadata (value) VALUES ('preserve-me')")
        }
        let tableNames = try tableNames(at: databaseURL)
        return Fixture(
            root: root,
            databaseURL: databaseURL,
            descriptor: descriptor,
            tableNamesBefore: tableNames
        )
    }

    private func tableNames(at url: URL) throws -> Set<String> {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.prepareDatabase { db in try db.usePassphrase(passphrase) }
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        return try queue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }
    }

    private func databaseSnapshot(at url: URL) throws -> [String: Data] {
        var snapshot: [String: Data] = [:]
        for suffix in ["", "-wal", "-shm"] {
            let fileURL = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                snapshot[suffix] = try Data(contentsOf: fileURL)
            }
        }
        return snapshot
    }

    private func metadataValue(at url: URL) throws -> String? {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.prepareDatabase { db in try db.usePassphrase(passphrase) }
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        return try queue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM existingMetadata")
        }
    }

    private struct Fixture {
        let root: URL
        let databaseURL: URL
        let descriptor: AutoFillCredentialDescriptor
        let tableNamesBefore: Set<String>
    }
}
