import Foundation

/// A handle to persisted pre-fetch admission, not selection or secret-release authority by itself.
nonisolated struct OfflineSyncCapture: Sendable {
    let id: UUID
    let operation: SyncOperationToken
    let lifecycleGeneration: UUID
}

/// Transaction-produced metadata evidence for the content fetched by one sync operation.
/// `item` contains ordinary metadata only; local usage fields are not source identity.
nonisolated struct OfflineSyncedMetadataProof: Sendable {
    let operationID: UUID
    let item: PassItem
    let shareID: String
    let descriptorInputs: [AutoFillDescriptorInput]
    let metadataGeneration: UUID?
}

/// Existing selection ownership and future vault membership are deliberately distinct.
nonisolated enum OfflineSyncOwnership: Sendable, Equatable {
    case selected(selectionGeneration: UUID, requestGeneration: UUID, metadataGeneration: UUID)
    case vaultMember(policyGeneration: UUID, wasKnownEligible: Bool)
}

/// Metadata-only planned work. No fetched item, ciphertext or secret key is retained here.
nonisolated struct OfflineSyncWork: Sendable {
    let key: OfflineSnapshotKey
    let shareID: String
    let itemType: ItemType
    let metadataProof: OfflineSyncedMetadataProof
    let ownership: OfflineSyncOwnership
    let capturedPendingRequestID: UUID?
    let expectedSourceModifyTime: Date?
}
