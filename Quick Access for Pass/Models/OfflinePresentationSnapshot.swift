import Foundation

/// A metadata-only view of the offline catalog. It never carries snapshot payloads or keys.
nonisolated struct OfflinePresentationSnapshot: Sendable, Equatable {
    let vaults: [OfflineVaultSettingsRow]
    let itemGroups: [OfflineItemSettingsGroup]
    let selectedVaultIDs: Set<String>
    let policyByItemID: [String: OfflineItemPolicy]
    let availabilityByItemID: [String: OfflineItemAvailability]

    static let empty = Self(vaults: [], itemGroups: [], selectedVaultIDs: [], policyByItemID: [:], availabilityByItemID: [:])
}

/// Streams committed, metadata-only offline catalog presentations.
nonisolated protocol OfflineCatalogObserving: Sendable {
    func snapshots() -> AsyncThrowingStream<OfflinePresentationSnapshot, Error>
}
