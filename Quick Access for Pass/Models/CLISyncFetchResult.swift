nonisolated struct CLISyncFetchResult: Sendable {
    let vaults: [CLIVault]
    let items: [(item: CLIItem, vaultId: String)]
    let skippedItems: [SkippedSyncItem]
    let presenceUncertainties: [SyncItemPresenceUncertainty]
    let contentProvenanceByVaultID: [String: CLISnapshotContentProvenance]
    let folderCatalogsByVaultID: [String: FolderCatalogFetchOutcome]

    init(
        vaults: [CLIVault], items: [(item: CLIItem, vaultId: String)], skippedItems: [SkippedSyncItem],
        presenceUncertainties: [SyncItemPresenceUncertainty],
        contentProvenanceByVaultID: [String: CLISnapshotContentProvenance] = [:],
        folderCatalogsByVaultID: [String: FolderCatalogFetchOutcome] = [:]
    ) {
        self.vaults = vaults
        self.items = items
        self.skippedItems = skippedItems
        self.presenceUncertainties = presenceUncertainties
        self.contentProvenanceByVaultID = contentProvenanceByVaultID
        self.folderCatalogsByVaultID = folderCatalogsByVaultID
    }
}
