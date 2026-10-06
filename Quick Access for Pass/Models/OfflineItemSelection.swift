import Foundation
import GRDB

/// Non-secret catalog metadata identifying an item selected for offline access.
nonisolated struct OfflineItemSelection: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "offlineItems"

    let itemId: String
    let vaultId: String
    let selectedAt: Date
    let lastRefreshedAt: Date?
    let cacheStatus: OfflineCacheStatus
    let isManuallySelected: Bool
    let selectionGeneration: UUID
}
