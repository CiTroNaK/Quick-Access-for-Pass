import Foundation

/// Non-secret repository evidence for one transient cached read and its final release.
nonisolated struct OfflineReleaseProof: Sendable, Equatable {
    let identity: OfflineSnapshotIdentity
    let selectionGeneration: UUID
    let isManuallySelected: Bool
    let itemType: ItemType
    let ciphertextDigest: Data // SHA-256 of ciphertext, never plaintext/key material
}

nonisolated enum OfflineReleaseError: Error, Sendable, Equatable {
    case revoked
    case alreadyConsumed
}
