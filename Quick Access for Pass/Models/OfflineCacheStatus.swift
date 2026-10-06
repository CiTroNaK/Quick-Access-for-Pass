import Foundation

/// Non-secret availability state for an item's device-bound offline snapshot.
nonisolated enum OfflineCacheStatus: String, Codable, Sendable, Equatable {
    /// No offline snapshot has been written for the selected item.
    case notCached
    /// An offline snapshot is available for the selected item.
    case cached
    /// A retained snapshot could not refresh; this is presented as stale and
    /// remains eligible only for the same catalog-authorized offline fallback.
    case failed
    /// The snapshot is unavailable after cache deletion succeeded but catalog deletion failed.
    case unavailable
}
