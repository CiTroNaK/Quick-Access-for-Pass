import Foundation

/// A metadata-only view of the offline catalog. It never carries snapshot payloads or keys.
nonisolated struct OfflinePresentationSnapshot: Sendable, Equatable {
    let vaults: [OfflineVaultSettingsRow]
    let itemGroups: [OfflineItemSettingsGroup]
    let selectedVaultIDs: Set<String>
    let policyByItemID: [String: OfflineItemPolicy]
    let availabilityByItemID: [String: OfflineItemAvailability]
    let folderRowsByVaultID: [String: [OfflineFolderSettingsRow]]
    let folderCatalogStatusByVaultID: [String: OfflineFolderCatalogStatus]
    let folderCatalogStampsByVaultID: [String: FolderFeatureStamp]
    let folderLocationsByItemID: [String: FolderLocationPresentation]

    init(vaults: [OfflineVaultSettingsRow], itemGroups: [OfflineItemSettingsGroup], selectedVaultIDs: Set<String>,
         policyByItemID: [String: OfflineItemPolicy], availabilityByItemID: [String: OfflineItemAvailability],
         folderRowsByVaultID: [String: [OfflineFolderSettingsRow]] = [:],
         folderCatalogStatusByVaultID: [String: OfflineFolderCatalogStatus] = [:],
         folderCatalogStampsByVaultID: [String: FolderFeatureStamp] = [:],
         folderLocationsByItemID: [String: FolderLocationPresentation] = [:]) {
        self.vaults = vaults
        self.itemGroups = itemGroups
        self.selectedVaultIDs = selectedVaultIDs
        self.policyByItemID = policyByItemID
        self.availabilityByItemID = availabilityByItemID
        self.folderRowsByVaultID = folderRowsByVaultID
        self.folderCatalogStatusByVaultID = folderCatalogStatusByVaultID
        self.folderCatalogStampsByVaultID = folderCatalogStampsByVaultID
        self.folderLocationsByItemID = folderLocationsByItemID
    }

    static let empty = Self(vaults: [], itemGroups: [], selectedVaultIDs: [], policyByItemID: [:], availabilityByItemID: [:])
}

/// Streams committed, metadata-only offline catalog presentations.
nonisolated protocol OfflineCatalogObserving: Sendable {
    func snapshots() -> AsyncThrowingStream<OfflinePresentationSnapshot, Error>
}
