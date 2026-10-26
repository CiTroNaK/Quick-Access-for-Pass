import Foundation

/// Non-secret repository evidence for one transient cached read and its final release.
nonisolated struct OfflineReleaseProof: Sendable, Equatable {
    let identity: OfflineSnapshotIdentity
    let selectionGeneration: UUID
    let isManuallySelected: Bool
    let itemType: ItemType
    let ciphertextDigest: Data // SHA-256 of ciphertext, never plaintext/key material
    let automaticCoverage: Set<OfflineAutomaticCoverage>

    init(identity: OfflineSnapshotIdentity, selectionGeneration: UUID, isManuallySelected: Bool,
         itemType: ItemType, ciphertextDigest: Data, automaticCoverage: Set<OfflineAutomaticCoverage>? = nil) {
        self.identity = identity
        self.selectionGeneration = selectionGeneration
        self.isManuallySelected = isManuallySelected
        self.itemType = itemType
        self.ciphertextDigest = ciphertextDigest
        // Legacy proof callers describe whole-vault coverage. Repository reads always pass explicit evidence.
        self.automaticCoverage = automaticCoverage ?? (isManuallySelected ? [] : [.vault(identity.key.vaultId)])
    }

    func replacingCoverage(_ coverage: Set<OfflineAutomaticCoverage>, manuallySelected: Bool? = nil) -> Self {
        Self(identity: identity, selectionGeneration: selectionGeneration,
             isManuallySelected: manuallySelected ?? isManuallySelected, itemType: itemType,
             ciphertextDigest: ciphertextDigest, automaticCoverage: coverage)
    }
}

nonisolated enum OfflineReleaseError: Error, Sendable, Equatable {
    case revoked
    case alreadyConsumed
}
