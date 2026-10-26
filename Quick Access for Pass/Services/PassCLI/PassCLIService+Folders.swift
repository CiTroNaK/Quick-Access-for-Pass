import Foundation

extension PassCLIService {
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
