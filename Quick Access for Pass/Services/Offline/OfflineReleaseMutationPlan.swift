import Foundation

nonisolated struct OfflineIncomingItemIdentity: Sendable {
    let vaultID: String
    let itemType: ItemType
    let isActive: Bool
}

/// One bounded graph projection, shared by all items rather than expanded per item.
nonisolated struct OfflineFolderMetadataReplacement: Sendable {
    let memberships: [String: CLIFolderMembership]
    let ancestorsByFolderID: [String: Set<String>]

    init(_ catalog: ValidatedFolderCatalog) {
        memberships = catalog.itemMemberships
        ancestorsByFolderID = Dictionary(grouping: catalog.ancestors, by: \.folderID)
            .mapValues { Set($0.map(\.ancestorID)) }
    }

    func ancestors(for itemID: String) -> Set<String>? {
        switch memberships[itemID] {
        case .root: return []
        case .folder(let id): return ancestorsByFolderID[id]
        case .unknown, nil: return nil
        }
    }
}

nonisolated struct OfflineMetadataReplacement: Sendable {
    let vaultIDs: Set<String>
    let itemsByID: [String: OfflineIncomingItemIdentity]
    let presenceUncertainties: [SyncItemPresenceUncertainty]
    let folderCatalogs: [String: OfflineFolderMetadataReplacement]

    init(vaultIDs: Set<String>, itemsByID: [String: OfflineIncomingItemIdentity],
         presenceUncertainties: [SyncItemPresenceUncertainty], folderCatalogs: [String: OfflineFolderMetadataReplacement] = [:]) {
        self.vaultIDs = vaultIDs
        self.itemsByID = itemsByID
        self.presenceUncertainties = presenceUncertainties
        self.folderCatalogs = folderCatalogs
    }
}

nonisolated enum OfflineReleaseMutationScope: Sendable {
    case none
    case keys(Set<OfflineSnapshotKey>)
    case itemID(String)
    case all
    case vaultOnly(vaultID: String)
    case folderOnly(vaultID: String, folderID: String)
    case snapshot(identity: OfflineSnapshotIdentity, ciphertextDigest: Data)
    case upsertItems([String: OfflineIncomingItemIdentity])
    case replaceItems([String: OfflineIncomingItemIdentity])
    case retainVaults(Set<String>)
    case reconcileSelections(validVaultIDs: Set<String>, currentVaultIDByItemID: [String: String])
    case replaceMetadata(OfflineMetadataReplacement)

    /// Bounded metadata-only constraints for captures whose repository proof has not arrived yet.
    enum PreBindConstraint {
        case none
        case invalidate
        case excludesVault
        case excludesFolder(String)
        case itemType(ItemType)
        case itemTypeAndFolders(ItemType, Set<String>)
    }

    func preBindConstraint(for key: OfflineSnapshotKey) -> PreBindConstraint {
        switch self {
        case .none:
            return .none
        case .keys, .itemID, .all, .snapshot:
            return directInvalidationConstraint(for: key)
        case .vaultOnly(let vaultID):
            return vaultID == key.vaultId ? .excludesVault : .none
        case .folderOnly(let vaultID, let folderID):
            return vaultID == key.vaultId ? .excludesFolder(folderID) : .none
        case .upsertItems(let items), .replaceItems(let items):
            return itemConstraint(for: key, items: items)
        case .retainVaults(let vaultIDs):
            return vaultIDs.contains(key.vaultId) ? .none : .invalidate
        case .reconcileSelections(let vaultIDs, let parents):
            return vaultIDs.contains(key.vaultId) && parents[key.itemId] == key.vaultId ? .none : .invalidate
        case .replaceMetadata(let replacement):
            return Self.constraint(for: key, replacement: replacement)
        }
    }

    /// Direct identity invalidation only; other scopes retain their coverage/metadata checks above.
    private func directInvalidationConstraint(for key: OfflineSnapshotKey) -> PreBindConstraint {
        switch self {
        case .keys(let keys):
            return keys.contains(key) ? .invalidate : .none
        case .itemID(let itemID):
            return itemID == key.itemId ? .invalidate : .none
        case .all:
            return .invalidate
        case .snapshot(let identity, _):
            return identity.key == key ? .invalidate : .none
        default:
            return .none
        }
    }

    private func itemConstraint(
        for key: OfflineSnapshotKey, items: [String: OfflineIncomingItemIdentity]
    ) -> PreBindConstraint {
        let absent: PreBindConstraint
        if case .upsertItems = self { absent = .none } else { absent = .invalidate }
        return Self.constraint(for: key, incoming: items[key.itemId], absent: absent)
    }

    private static func constraint(
        for key: OfflineSnapshotKey, replacement: OfflineMetadataReplacement
    ) -> PreBindConstraint {
        guard replacement.vaultIDs.contains(key.vaultId) else { return .invalidate }
        // Decoded incoming items take precedence over lossy-list retention evidence.
        if let incoming = replacement.itemsByID[key.itemId] {
            guard incoming.vaultID == key.vaultId, incoming.isActive else { return .invalidate }
            if let ancestors = replacement.folderCatalogs[key.vaultId]?.ancestors(for: key.itemId) {
                return .itemTypeAndFolders(incoming.itemType, ancestors)
            }
            return .itemType(incoming.itemType)
        }
        let retained = replacement.presenceUncertainties.contains {
            $0.vaultID == key.vaultId && ($0.hasUnidentifiedSkippedItems || $0.skippedItemIDs.contains(key.itemId))
        }
        return retained ? .none : .invalidate
    }

    func matches(_ proof: OfflineReleaseProof) -> Bool {
        if case .snapshot(let identity, let digest) = self {
            return proof.identity == identity && proof.ciphertextDigest == digest
        }
        switch preBindConstraint(for: proof.identity.key) {
        case .none: return false
        case .invalidate: return true
        case .excludesVault:
            var coverage = OfflineCoverageRestrictions()
            coverage.excludeVault()
            return !coverage.allows(proof)
        case .excludesFolder(let id):
            var coverage = OfflineCoverageRestrictions()
            coverage.excludeFolder(id)
            return !coverage.allows(proof)
        case .itemType(let type): return proof.itemType != type
        case .itemTypeAndFolders(let type, let ids):
            var coverage = OfflineCoverageRestrictions()
            coverage.restrictFolders(to: ids)
            return proof.itemType != type || !coverage.allows(proof)
        }
    }

    private static func constraint(
        for key: OfflineSnapshotKey, incoming: OfflineIncomingItemIdentity?, absent: PreBindConstraint
    ) -> PreBindConstraint {
        guard let incoming else { return absent }
        guard incoming.vaultID == key.vaultId, incoming.isActive else { return .invalidate }
        return .itemType(incoming.itemType)
    }
}

nonisolated struct OfflineManualPromotion: Sendable {
    let key: OfflineSnapshotKey
    let selectionGeneration: UUID
}

nonisolated enum OfflineReleaseMutationOutcome: Sendable {
    case committed(manualPromotions: [OfflineManualPromotion], automaticPromotions: [OfflineSnapshotKey: OfflineAutomaticPromotion] = [:])
    case rolledBack
    case admissionFinished // Outer service intent owns no SQL outcome/events.
}

nonisolated struct OfflineMutationUpdate<Value: Sendable>: Sendable {
    let value: Value
    let manualPromotions: [OfflineManualPromotion]
    let automaticPromotions: [OfflineSnapshotKey: OfflineAutomaticPromotion]

    init(value: Value, manualPromotions: [OfflineManualPromotion], automaticPromotions: [OfflineSnapshotKey: OfflineAutomaticPromotion] = [:]) {
        self.value = value
        self.manualPromotions = manualPromotions
        self.automaticPromotions = automaticPromotions
    }
}
