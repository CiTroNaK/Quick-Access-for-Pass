import Foundation

extension SyncCoordinator {
    func synchronizeFetchedMetadata(_ fetchResult: CLISyncFetchResult, operation: SyncOperationToken,
                                    capture: OfflineSyncCapture? = nil) async throws {
        try requireCurrentSync(operation)
        let projection = projectSyncMetadata(vaults: fetchResult.vaults, cliItems: fetchResult.items)
        let db = databaseManager
        let synchronization = try await db.synchronizeMetadata(
            vaults: projection.vaults,
            items: projection.items,
            descriptors: projection.descriptorInputs,
            presenceUncertainties: fetchResult.presenceUncertainties,
            operation: operation
        )
        // This registration happens only after the metadata transaction
        // commits; checkpoint busy/error never changes sync success.
        if synchronization.didDeleteOfflineData {
            await maintenance?.requestCheckpoint()
        }
        try requireCurrentSync(operation)
        let descriptors = try db.allAutoFillDescriptors()
        try await identitySynchronizer.reconcile(descriptors: descriptors, isCurrent: { operation.isCurrent })
        try requireCurrentSync(operation)
        // Only original pre-fetch admission can consume this result. A service becoming ready
        // after fetch cannot gain admission to already-fetched plaintext. Ordinary sync never
        // also queues the old blanket-refresh path; explicit selection/Retry/recovery retain it.
        if let capture {
            try await offlineModeService?.consumeSyncResult(
                fetchResult, capture: capture, metadataProofs: synchronization.offlineMetadataProofs,
                allowMembershipExpansion: fetchResult.skippedItems.isEmpty && fetchResult.presenceUncertainties.allSatisfy {
                    $0.skippedItemIDs.isEmpty && !$0.hasUnidentifiedSkippedItems
                }
            )
        }
        try requireCurrentSync(operation)
    }

    func requireCurrentSync(_ operation: SyncOperationToken) throws {
        try Task.checkCancellation()
        guard operation.isCurrent else { throw CancellationError() }
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
