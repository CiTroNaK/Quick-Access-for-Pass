import Foundation

extension PassCLIService {
    private static let maximumConcurrentFolderLists = 4

    /// Separate metadata-only commands run a few vaults at a time, never an unbounded fan-out.
    func fetchFolderCatalogs(vaults: [CLIVault], memberships: [String: [String: CLIFolderMembership]],
                             selection: PassCLISelection, stamp: FolderFeatureStamp?) async throws -> [String: FolderCatalogFetchOutcome] {
        try await withThrowingTaskGroup(of: (vaultID: String, outcome: FolderCatalogFetchOutcome).self) { group in
            var pending = vaults[...]
            func addNext() {
                guard let vault = pending.popFirst() else { return }
                let vaultMemberships = memberships[vault.vaultId]
                group.addTask {
                    try Task.checkCancellation()
                    let outcome = await self.fetchFolderCatalog(vault: vault, memberships: vaultMemberships,
                                                                selection: selection, stamp: stamp)
                    return (vaultID: vault.vaultId, outcome: outcome)
                }
            }
            for _ in 0..<Self.maximumConcurrentFolderLists { addNext() }
            var catalogs: [String: FolderCatalogFetchOutcome] = [:]
            for try await result in group {
                catalogs[result.vaultID] = result.outcome
                addNext()
            }
            return catalogs
        }
    }

    /// No full item content crosses this metadata-only boundary. Failure defers folders,
    /// never ordinary metadata sync or existing cached release/removal.
    func fetchFolderCatalog(vault: CLIVault, memberships: [String: CLIFolderMembership]?,
                            selection: PassCLISelection, stamp: FolderFeatureStamp?) async -> FolderCatalogFetchOutcome {
        guard let stamp else { return .unsupported }
        guard !Task.isCancelled, folderFeatureGate.isCurrent(stamp), cliSelection == selection,
              memberships != nil else { return .unavailable }
        do {
            let data = try await folderListData(shareID: vault.shareId, selection: selection, stamp: stamp)
            guard !Task.isCancelled, folderFeatureGate.isCurrent(stamp), cliSelection == selection else {
                return .unavailable
            }
            return .complete(try CLIFolderCatalogParser.parse(data, vault: vault, memberships: memberships, stamp: stamp))
        } catch {
            // Folder names/errors are untrusted display metadata; do not log their raw bytes.
            return .unavailable
        }
    }
}
