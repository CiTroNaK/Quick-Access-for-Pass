import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import Quick_Access_for_Pass

@Suite("Database startup preparation")
struct DatabaseStartupPreparationTests {
    private let passphrase = Data("database-startup-fixture-passphrase".utf8)

    @Test("new local database creates its directory and passphrase")
    func newDatabaseCreatesLocalDirectoryAndPassphrase() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let keychain = fixture.keychain(result: .success(nil))

        let prepared = try DatabaseStartupPreparation.prepare(
            fileManager: .default,
            keychainService: keychain,
            databaseURL: fixture.databaseURL
        )

        #expect(prepared.databaseURL == fixture.databaseURL)
        #expect(FileManager.default.fileExists(atPath: fixture.databaseURL.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: fixture.databaseURL.path) == false)
        #expect(fixture.calls == [.retrieve, .add])
    }

    @Test("existing local database uses its existing passphrase")
    func existingDatabaseUsesExistingPassphrase() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createDatabase(passphrase: passphrase)
        let keychain = fixture.keychain(result: .success(passphrase))

        let prepared = try DatabaseStartupPreparation.prepare(
            fileManager: .default,
            keychainService: keychain,
            databaseURL: fixture.databaseURL
        )

        #expect(prepared.databaseURL == fixture.databaseURL)
        #expect(prepared.passphrase == passphrase)
        #expect(fixture.calls == [.retrieve])
    }

    @Test("existing local database with a missing passphrase fails without creating one")
    func existingDatabaseMissingPassphraseFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createDatabase(passphrase: passphrase)
        let before = try fixture.snapshot()

        #expect(throws: DatabaseStartupPreparation.Error.passphraseMissing) {
            _ = try DatabaseStartupPreparation.prepare(
                fileManager: .default,
                keychainService: fixture.keychain(result: .success(nil)),
                databaseURL: fixture.databaseURL
            )
        }
        #expect(fixture.calls == [.retrieve])
        #expect(try fixture.snapshot() == before)
    }

    @Test("existing local database with a locked passphrase fails without creating one")
    func existingDatabaseLockedPassphraseFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createDatabase(passphrase: passphrase)
        let before = try fixture.snapshot()

        #expect(throws: KeychainError.self) {
            _ = try DatabaseStartupPreparation.prepare(
                fileManager: .default,
                keychainService: fixture.keychain(
                    result: .failure(.retrieveFailed(errSecInteractionNotAllowed))
                ),
                databaseURL: fixture.databaseURL
            )
        }
        #expect(fixture.calls == [.retrieve])
        #expect(try fixture.snapshot() == before)
    }

    @Test("wrong passphrase validation preserves database and sidecar bytes")
    func wrongPassphrasePreservesDatabaseFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createDatabase(passphrase: passphrase)
        let walURL = URL(fileURLWithPath: fixture.databaseURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: fixture.databaseURL.path + "-shm")
        try Data("wal".utf8).write(to: walURL)
        try Data("shm".utf8).write(to: shmURL)
        let before = try fixture.snapshot()

        #expect(throws: (any Swift.Error).self) {
            _ = try DatabaseStartupPreparation.prepare(
                fileManager: .default,
                keychainService: fixture.keychain(result: .success(Data("wrong-passphrase".utf8))),
                databaseURL: fixture.databaseURL
            )
        }
        #expect(fixture.calls == [.retrieve])
        #expect(try fixture.snapshot() == before)
    }

    private final class Fixture: Sendable {
        let root: URL
        let databaseURL: URL
        private let recordedCalls = Mutex<[KeychainPassphraseQueryKind]>([])

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("DatabaseStartupPreparationTests-\(UUID().uuidString)")
            databaseURL = root.appendingPathComponent("Application Support/QuickAccessForPass/app.db")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        var calls: [KeychainPassphraseQueryKind] {
            recordedCalls.withLock { $0 }
        }

        func keychain(result: Result<Data?, KeychainError>) -> KeychainService {
            KeychainService(
                serviceName: "test",
                accessGroup: AutoFillConstants.keychainAccessGroup,
                backend: .init(
                    retrieve: { query in
                        self.recordedCalls.withLock { $0.append(query.kind) }
                        return result
                    },
                    add: { query in
                        self.recordedCalls.withLock { $0.append(query.kind) }
                        return .success(())
                    },
                    update: { query in
                        self.recordedCalls.withLock { $0.append(query.kind) }
                        return .success(())
                    },
                    delete: { _ in .success(()) }
                )
            )
        }

        func createDatabase(passphrase: Data) throws {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = try DatabaseManager(path: databaseURL.path, passphrase: passphrase)
        }

        func snapshot() throws -> [String: Data] {
            try Dictionary(uniqueKeysWithValues: ["", "-wal", "-shm"].compactMap { suffix in
                let fileURL = URL(fileURLWithPath: databaseURL.path + suffix)
                guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
                return (suffix, Data(SHA256.hash(data: try Data(contentsOf: fileURL))))
            })
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
