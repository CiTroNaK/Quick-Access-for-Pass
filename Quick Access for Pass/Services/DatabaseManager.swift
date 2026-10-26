import Foundation
import GRDB
import Synchronization

nonisolated final class DatabaseManager: Sendable {
    let writer: any DatabaseWriter
    let reader: any DatabaseReader
    let offlineReleaseAuthority = OfflineReleaseAuthority()
    private let syncOperationAuthority = SyncOperationAuthority()
    let offlineMutationTesting: OfflineMutationTesting?
    // Optimization only, never admission/release authority. Monotonic for this connection
    // lifetime, so rollback/reset cannot incorrectly hide persisted folder dependencies.
    private let folderMetadataTracking = Mutex(false)

    func tracksFolderMetadata(recordingEvidence: Bool) -> Bool {
        folderMetadataTracking.withLock { tracked in
            if recordingEvidence { tracked = true }
            return tracked
        }
    }

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
        let hasFolderState = try pool.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM folderCatalogState)") ?? false
        }
        if hasFolderState { folderMetadataTracking.withLock { $0 = true } }
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

    func beginSyncOperation() -> SyncOperationToken { syncOperationAuthority.beginOperation() }

    func invalidateSyncOperations() { syncOperationAuthority.invalidate() }

    func clearAll() throws {
        invalidateSyncOperations()
        try writeOfflineMutation(submissionScope: .all) { db in
            try db.execute(sql: "DELETE FROM offlineSyncCaptures")
            try PassItem.deleteAll(db)
            try PassVault.deleteAll(db)
            return OfflineMutationUpdate(value: (), manualPromotions: [])
        }
    }

    /// Clears ordinary metadata and cascaded offline selections in one database transaction.
    func clearMetadata() async throws {
        invalidateSyncOperations()
        try await writeOfflineMutation(submissionScope: .all) { db in
            try db.execute(sql: "DELETE FROM offlineSyncCaptures")
            try PassItem.deleteAll(db)
            try PassVault.deleteAll(db)
            return OfflineMutationUpdate(value: (), manualPromotions: [])
        }
    }
}
