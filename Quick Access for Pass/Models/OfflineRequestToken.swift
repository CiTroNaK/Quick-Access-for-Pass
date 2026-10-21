import Foundation

nonisolated enum OfflineRequestKind: Sendable, Equatable {
    case selection
    case materialization
    case vaultSelection(policyGeneration: UUID)
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
}
