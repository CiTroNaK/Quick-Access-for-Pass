import Foundation

/// A bounded writer input: ciphertext, original metadata evidence, and a success timestamp. Never a decoded item.
nonisolated struct OfflineSyncPublication: Sendable {
    let work: OfflineSyncWork
    let prepared: PreparedOfflineSnapshot
    let refreshedAt: Date
    let source: OfflineSyncContentSource

    init(work: OfflineSyncWork, prepared: PreparedOfflineSnapshot, refreshedAt: Date, source: OfflineSyncContentSource = .syncList) {
        self.work = work
        self.prepared = prepared
        self.refreshedAt = refreshedAt
        self.source = source
    }
}

/// Live fallback may legitimately observe a newer payload than the metadata listing.
/// This describes only the successful source marker, never selection or publication authority.
nonisolated enum OfflineSyncContentSource: Sendable {
    case syncList
    case liveFallback
}

nonisolated enum OfflineSyncPublicationLimits {
    static let items = 32
    static let ciphertextBytes = 8 * 1024 * 1024
}
