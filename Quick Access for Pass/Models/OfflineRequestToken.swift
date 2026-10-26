import Foundation

nonisolated enum OfflineRequestKind: Sendable, Equatable {
    case selection
    case materialization
    case vaultSelection(policyGeneration: UUID)
    case folderSelection(folderID: String, policyGeneration: UUID)
    case refresh
}

/// Non-secret ownership token for one pending offline snapshot request.
nonisolated struct OfflineRequestToken: Sendable {
    let id: UUID
    let key: OfflineSnapshotKey
    let shareID: String
    let metadataModifyTime: Date
    let itemType: ItemType
    let selectionGeneration: UUID
    let metadataGeneration: UUID
    let requestGeneration: UUID
    let folderAdmission: OfflineFolderRequestAdmission?

    init(id: UUID, key: OfflineSnapshotKey, shareID: String, metadataModifyTime: Date, itemType: ItemType,
         selectionGeneration: UUID, metadataGeneration: UUID, requestGeneration: UUID,
         folderAdmission: OfflineFolderRequestAdmission? = nil) {
        self.id = id
        self.key = key
        self.shareID = shareID
        self.metadataModifyTime = metadataModifyTime
        self.itemType = itemType
        self.selectionGeneration = selectionGeneration
        self.metadataGeneration = metadataGeneration
        self.requestGeneration = requestGeneration
        self.folderAdmission = folderAdmission
    }
}

/// Codec identity validation only; this value grants no pending-request or selection ownership.
nonisolated struct OfflineSnapshotPreparationIdentity: Sendable {
    let key: OfflineSnapshotKey
    let shareID: String
    let itemType: ItemType
}
