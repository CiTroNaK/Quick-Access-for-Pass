nonisolated struct CLISyncFetchResult: Sendable {
    let vaults: [CLIVault]
    let items: [(item: CLIItem, vaultId: String)]
    let skippedItems: [SkippedSyncItem]
    let presenceUncertainties: [SyncItemPresenceUncertainty]
}
