import Foundation
import GRDB

nonisolated struct SearchService: Sendable {
    private let databaseManager: DatabaseManager

    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
    }

    func search(query: String) throws -> [PassItem] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            return try databaseManager.allActiveItems()
        }
        return try databaseManager.searchItems(query: query)
    }

    /// GRDB schedules the metadata projection off the main actor, independently of secret lookup.
    func loadFolderLocations(for itemIDs: Set<String>) async throws -> [String: FolderLocationPresentation] {
        try await databaseManager.reader.read { db in
            try DatabaseManager.folderLocations(for: itemIDs, in: db)
        }
    }

    func recordUsage(itemId: String) throws {
        try databaseManager.recordUsage(itemId: itemId)
    }

    func vaultName(for vaultId: String) throws -> String? {
        try databaseManager.vaultName(for: vaultId)
    }

    func vaultShareId(for vaultId: String) throws -> String? {
        try databaseManager.vaultShareId(for: vaultId)
    }
}
