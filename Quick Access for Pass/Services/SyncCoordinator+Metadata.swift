import Foundation

extension SyncCoordinator {
    func synchronizeFetchedMetadata(_ fetchResult: CLISyncFetchResult) async throws {
        let projection = projectSyncMetadata(vaults: fetchResult.vaults, cliItems: fetchResult.items)
        let db = databaseManager
        let synchronization = try await db.synchronizeMetadata(
            vaults: projection.vaults,
            items: projection.items,
            descriptors: projection.descriptorInputs,
            presenceUncertainties: fetchResult.presenceUncertainties
        )
        // This registration happens only after the metadata transaction
        // commits; checkpoint busy/error never changes sync success.
        if synchronization.didDeleteOfflineData {
            await maintenance?.requestCheckpoint()
        }
        try Task.checkCancellation()
        try await identitySynchronizer.reconcile(descriptors: synchronization.descriptors)
        try Task.checkCancellation()
        // Queue only metadata-backed work after trusted reconciliation.
        // Admission is nonblocking; secret preparation is independent of
        // ordinary metadata sync completion and loading state.
        await offlineModeService?.metadataDidSynchronize(
            allowMembershipExpansion: fetchResult.skippedItems.isEmpty && fetchResult.presenceUncertainties.allSatisfy {
                $0.skippedItemIDs.isEmpty && !$0.hasUnidentifiedSkippedItems
            },
            eligibleItemIDs: Set(projection.items.map(\.id))
        )
        try Task.checkCancellation()
    }

    private func projectSyncMetadata(
        vaults: [CLIVault],
        cliItems: [(item: CLIItem, vaultId: String)]
    ) -> (vaults: [PassVault], items: [PassItem], descriptorInputs: [AutoFillDescriptorInput]) {
        let passVaults = vaults.map { PassVault(from: $0) }
        let shareIDsByVaultID = Dictionary(
            uniqueKeysWithValues: passVaults.map { ($0.id, $0.shareId) }
        )
        var passItems: [PassItem] = []
        var descriptorInputs: [AutoFillDescriptorInput] = []
        passItems.reserveCapacity(cliItems.count)
        for cliItem in cliItems {
            let metadata = PassItem(from: cliItem.item, vaultId: cliItem.vaultId)
            passItems.append(metadata)
            if let shareID = shareIDsByVaultID[cliItem.vaultId] {
                descriptorInputs.append(contentsOf: AutoFillCredentialDescriptor.inputs(
                    from: cliItem.item,
                    metadata: metadata,
                    shareID: shareID
                ))
            }
        }
        return (passVaults, passItems, descriptorInputs)
    }
}
