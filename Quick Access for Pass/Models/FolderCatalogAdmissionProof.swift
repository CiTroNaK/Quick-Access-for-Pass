import Foundation

/// Current committed metadata evidence for expansion, not cached-content release authority.
nonisolated struct FolderCatalogAdmissionProof: Sendable, Equatable {
    let vaultID: String
    let observationID: UUID
    let membershipGeneration: UUID
    let stamp: FolderFeatureStamp
}
