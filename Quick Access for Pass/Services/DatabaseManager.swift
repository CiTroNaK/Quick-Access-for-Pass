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
