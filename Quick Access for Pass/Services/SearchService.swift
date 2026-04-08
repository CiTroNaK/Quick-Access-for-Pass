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

    func recordUsage(itemId: String) throws {
        try databaseManager.recordUsage(itemId: itemId)
    }

    func vaultName(for vaultId: String) throws -> String? {
        try databaseManager.vaultName(for: vaultId)
    }
}
