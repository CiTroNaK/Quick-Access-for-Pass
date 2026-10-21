import CryptoKit
import Foundation
import GRDB

/// The host-owned encrypted database location and passphrase prepared for startup.
nonisolated struct PreparedDatabase: Sendable {
    let databaseURL: URL
    let passphrase: Data
}

/// Prepares the host-owned local database without relocating or replacing existing data.
nonisolated enum DatabaseStartupPreparation {
    enum Error: Swift.Error, LocalizedError, Equatable {
        case applicationSupportUnavailable
        case inconsistentDatabaseFiles
        case passphraseMissing

        var errorDescription: String? {
            switch self {
            case .applicationSupportUnavailable:
                String(localized: "Application Support is unavailable.")
            case .inconsistentDatabaseFiles:
                String(localized: "The local database sidecar files are inconsistent. No database was changed.")
            case .passphraseMissing:
                String(localized: "The existing local database passphrase is unavailable.")
            }
        }
    }

    /// Prepares the production Application Support database and its passphrase for host startup.
    static func prepare(
        fileManager: FileManager = .default,
        keychainService: KeychainService = KeychainService()
    ) throws -> PreparedDatabase {
        let databaseURL: URL
        do {
            databaseURL = try AutoFillConstants.legacyDatabaseURL(fileManager: fileManager)
        } catch AutoFillConstantsError.applicationSupportUnavailable {
            throw Error.applicationSupportUnavailable
        }
        return try prepare(
            fileManager: fileManager,
            keychainService: keychainService,
            databaseURL: databaseURL
        )
    }

    /// Prepares an injected host-local database location for tests without accessing App Group storage.
    static func prepare(
        fileManager: FileManager,
        keychainService: KeychainService,
        databaseURL: URL
    ) throws -> PreparedDatabase {
        try HardenedDatabaseFiles.prepareDatabaseDirectory(for: databaseURL)
        if try databaseExists(at: databaseURL, fileManager: fileManager) {
            try HardenedDatabaseFiles.protectDatabaseFiles(at: databaseURL)
            guard let passphrase = try keychainService.retrievePassphrase() else {
                throw Error.passphraseMissing
            }
            try validateReadOnly(databaseURL: databaseURL, passphrase: passphrase, fileManager: fileManager)
            try HardenedDatabaseFiles.protectDatabaseFiles(at: databaseURL)
            return PreparedDatabase(databaseURL: databaseURL, passphrase: passphrase)
        }

        return PreparedDatabase(
            databaseURL: databaseURL,
            passphrase: try keychainService.getOrCreatePassphrase()
        )
    }

    private static func databaseExists(at databaseURL: URL, fileManager: FileManager) throws -> Bool {
        let databaseExists = fileManager.fileExists(atPath: databaseURL.path)
        let walExists = fileManager.fileExists(atPath: databaseURL.path + "-wal")
        let shmExists = fileManager.fileExists(atPath: databaseURL.path + "-shm")
        guard databaseExists || (!walExists && !shmExists) else {
            throw Error.inconsistentDatabaseFiles
        }
        guard walExists == shmExists else {
            throw Error.inconsistentDatabaseFiles
        }
        return databaseExists
    }

    private static func validateReadOnly(
        databaseURL: URL,
        passphrase: Data,
        fileManager: FileManager
    ) throws {
        let suffixes = try databaseSetSuffixes(databaseURL: databaseURL, fileManager: fileManager)
        let originalHashes = try databaseSetHashes(databaseURL: databaseURL, suffixes: suffixes)
        let stagingDirectoryURL = fileManager.temporaryDirectory.appendingPathComponent(
            "DatabaseStartupPreflight-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagingDirectoryURL, withIntermediateDirectories: false)
        try HardenedDatabaseFiles.prepareDatabaseDirectory(
            for: stagingDirectoryURL.appendingPathComponent(AutoFillConstants.databaseFileName)
        )
        defer { try? fileManager.removeItem(at: stagingDirectoryURL) }

        let stagedDatabaseURL = stagingDirectoryURL.appendingPathComponent(
            AutoFillConstants.databaseFileName,
            isDirectory: false
        )
        for suffix in suffixes {
            try fileManager.copyItem(
                at: URL(fileURLWithPath: databaseURL.path + suffix),
                to: URL(fileURLWithPath: stagedDatabaseURL.path + suffix)
            )
        }
        guard try databaseSetHashes(databaseURL: databaseURL, suffixes: suffixes) == originalHashes,
              try databaseSetHashes(databaseURL: stagedDatabaseURL, suffixes: suffixes) == originalHashes else {
            throw Error.inconsistentDatabaseFiles
        }
        try HardenedDatabaseFiles.protectDatabaseFiles(at: stagedDatabaseURL)

        var configuration = Configuration()
        configuration.readonly = true
        configuration.prepareDatabase { database in
            try EncryptedDatabaseConfiguration.prepare(database, passphrase: passphrase)
        }
        let queue = try DatabaseQueue(path: stagedDatabaseURL.path, configuration: configuration)
        try queue.read { database in
            _ = try Int.fetchOne(database, sql: "SELECT count(*) FROM sqlite_master")
            guard try String.fetchOne(database, sql: "PRAGMA quick_check") == "ok" else {
                throw DatabaseError(resultCode: .SQLITE_CORRUPT)
            }
        }
    }

    private static func databaseSetSuffixes(
        databaseURL: URL,
        fileManager: FileManager
    ) throws -> [String] {
        let walExists = fileManager.fileExists(atPath: databaseURL.path + "-wal")
        let shmExists = fileManager.fileExists(atPath: databaseURL.path + "-shm")
        guard walExists == shmExists else {
            throw Error.inconsistentDatabaseFiles
        }
        return walExists ? ["", "-wal", "-shm"] : [""]
    }

    private static func databaseSetHashes(
        databaseURL: URL,
        suffixes: [String]
    ) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: suffixes.map { suffix in
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            return (suffix, Data(SHA256.hash(data: try Data(contentsOf: url))))
        })
    }
}
