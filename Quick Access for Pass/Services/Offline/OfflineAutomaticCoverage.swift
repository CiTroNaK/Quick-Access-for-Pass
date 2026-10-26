import Foundation

/// Non-secret policy identity. Folder labels and paths never participate in release authorization.
nonisolated enum OfflineAutomaticCoverage: Sendable, Hashable {
    case vault(String)
    case folder(vaultID: String, folderID: String)
}

/// A committed permission gain for an existing selection generation, never a resurrected read.
nonisolated struct OfflineAutomaticPromotion: Sendable {
    let key: OfflineSnapshotKey
    let selectionGeneration: UUID
    let coverage: Set<OfflineAutomaticCoverage>
}

/// Bounded constraints for captures still waiting for repository evidence.
/// Known ancestry is at most 64 IDs. Before it arrives, exclusions are bounded by the
/// catalog's 10,000-folder budget; overflow fails closed for folder-derived coverage.
nonisolated struct OfflineCoverageRestrictions {
    private var excludesVault = false
    private var excludedFolders: Set<String> = []
    private var allowedFolders: Set<String>?

    mutating func excludeVault() { excludesVault = true }

    mutating func excludeFolder(_ id: String) {
        if allowedFolders != nil { allowedFolders?.remove(id); return }
        excludedFolders.insert(id)
        if excludedFolders.count > FolderCatalogLimits.maximumFolders {
            allowedFolders = []
            excludedFolders.removeAll()
        }
    }

    mutating func restrictFolders(to ids: Set<String>) {
        allowedFolders = (allowedFolders ?? ids).intersection(ids).subtracting(excludedFolders)
        excludedFolders.removeAll()
    }

    mutating func admitCommittedGain(_ sources: Set<OfflineAutomaticCoverage>, vaultID: String) {
        for source in sources {
            switch source {
            case .vault(let id) where id == vaultID: excludesVault = false
            case .folder(let id, let folderID) where id == vaultID:
                excludedFolders.remove(folderID)
                if allowedFolders != nil { allowedFolders?.insert(folderID) }
            default: break
            }
        }
    }

    func allows(_ proof: OfflineReleaseProof) -> Bool {
        if proof.isManuallySelected { return true }
        return proof.automaticCoverage.contains { allows($0, vaultID: proof.identity.key.vaultId) }
    }

    func permittedSources(_ sources: Set<OfflineAutomaticCoverage>, vaultID: String) -> Set<OfflineAutomaticCoverage> {
        Set(sources.filter { allows($0, vaultID: vaultID) })
    }

    private func allows(_ source: OfflineAutomaticCoverage, vaultID: String) -> Bool {
        switch source {
        case .vault(let id): return id == vaultID && !excludesVault
        case .folder(let id, let folderID):
            return id == vaultID && !excludedFolders.contains(folderID)
                && (allowedFolders?.contains(folderID) ?? true)
        }
    }
}
