import Foundation

/// Identifies a committed whole-vault offline selection policy.
nonisolated struct OfflineVaultSelection: Sendable, Equatable {
    let vaultID: String
    let generation: UUID
}

/// Describes explicit item intent alongside any encompassing vault policy.
nonisolated struct OfflineItemPolicy: Sendable, Equatable {
    let key: OfflineSnapshotKey
    let isManuallySelected: Bool
    let vaultSelection: OfflineVaultSelection?
    let isExcluded: Bool
}

/// Identifies why selected metadata should produce or refresh a snapshot.
nonisolated enum OfflineSnapshotWorkIntent: Sendable, Equatable {
    case materialize(selectionGeneration: UUID)
    case vaultMaterialize(policyGeneration: UUID)
    case refresh(selectionGeneration: UUID)
}

/// Metadata-only description of eligible snapshot work.
nonisolated struct OfflineSnapshotWorkCandidate: Sendable, Equatable {
    let key: OfflineSnapshotKey
    let shareID: String
    let metadataModifyTime: Date
    let itemType: ItemType
    let intent: OfflineSnapshotWorkIntent
}

/// Non-secret state of selection observation.
nonisolated enum OfflineSelectionObservationStatus: Sendable {
    case starting
    case fresh
    case failed
}
