import Darwin
import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("Hardened database storage")
struct HardenedDatabaseStorageTests {
    @Test("owner comparison accepts only the expected UID")
    func ownerComparison() {
        #expect(HardenedDatabaseFiles.ownerIsValid(actual: 501, expected: 501))
        #expect(!HardenedDatabaseFiles.ownerIsValid(actual: 501, expected: 502))
    }

    @Test(arguments: [UnsafePath.symlink, .wrongObjectType])
    func unsafeExistingDatabasePathsAreRejected(_ unsafePath: UnsafePath) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createUnsafeDatabasePath(unsafePath)

        #expect(throws: (any Error).self) {
            try DatabaseStartupPreparation.prepare(
                fileManager: .default,
                keychainService: fixture.keychain(),
                databaseURL: fixture.databaseURL
            )
        }
    }

    @Test("private directory and encrypted database files are protected")
    func protectedDatabaseFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        _ = try DatabaseStartupPreparation.prepare(
            fileManager: .default,
            keychainService: fixture.keychain(),
            databaseURL: fixture.databaseURL
        )
        let database = try DatabaseManager(path: fixture.databaseURL.path, passphrase: fixture.passphrase)
        try database.writer.write { connection in
            _ = try String.fetchOne(connection, sql: "PRAGMA journal_mode = WAL")
            try connection.execute(sql: "CREATE TABLE storageTest (value TEXT NOT NULL)")
            try connection.execute(sql: "INSERT INTO storageTest (value) VALUES ('value')")
        }
        try HardenedDatabaseFiles.protectDatabaseFiles(at: fixture.databaseURL)

        #expect(permissions(of: fixture.databaseURL.deletingLastPathComponent()) == 0o700)
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: fixture.databaseURL.path + suffix)
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(permissions(of: url) == 0o600)
            #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        }
        let raw = try Data(contentsOf: fixture.databaseURL)
        #expect(raw.range(of: fixture.passphrase) == nil)
    }

    private func permissions(of url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber else {
            return nil
        }
        return permissions.intValue & 0o777
    }

    enum UnsafePath: String, CaseIterable, CustomTestStringConvertible {
        case symlink
        case wrongObjectType

        var testDescription: String { rawValue }
    }

    private final class Fixture: Sendable {
        let root: URL
        let databaseURL: URL
        let passphrase = Data("test-file-protection-passphrase".utf8)

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            databaseURL = root
                .appendingPathComponent("QuickAccessForPass", isDirectory: true)
                .appendingPathComponent("app.db", isDirectory: false)
        }

        func keychain() -> KeychainService {
            KeychainService(
                serviceName: "test",
                accessGroup: AutoFillConstants.keychainAccessGroup,
                backend: .init(
                    retrieve: { _ in .success(nil) },
                    add: { _ in .success(()) },
                    update: { _ in .success(()) },
                    delete: { _ in .success(()) }
                )
            )
        }

        func createUnsafeDatabasePath(_ unsafePath: UnsafePath) throws {
            let directory = databaseURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            switch unsafePath {
            case .symlink:
                let target = root.appendingPathComponent("target.db")
                try Data("target".utf8).write(to: target)
                try FileManager.default.createSymbolicLink(at: databaseURL, withDestinationURL: target)
            case .wrongObjectType:
                try FileManager.default.createDirectory(at: databaseURL, withIntermediateDirectories: false)
            }
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
