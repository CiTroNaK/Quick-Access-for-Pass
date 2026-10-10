import Foundation

nonisolated struct OfflineIncomingItemIdentity: Sendable {
    let vaultID: String
    let itemType: ItemType
    let isActive: Bool
}

nonisolated struct OfflineMetadataReplacement: Sendable {
    let vaultIDs: Set<String>
    let itemsByID: [String: OfflineIncomingItemIdentity]
    let presenceUncertainties: [SyncItemPresenceUncertainty]
}

nonisolated enum OfflineReleaseMutationScope: Sendable {
    case none
    case keys(Set<OfflineSnapshotKey>)
    case itemID(String)
    case all
    case vaultOnly(vaultID: String)
    case snapshot(identity: OfflineSnapshotIdentity, ciphertextDigest: Data)
    case upsertItems([String: OfflineIncomingItemIdentity])
    case replaceItems([String: OfflineIncomingItemIdentity])
    case retainVaults(Set<String>)
    case reconcileSelections(validVaultIDs: Set<String>, currentVaultIDByItemID: [String: String])
    case replaceMetadata(OfflineMetadataReplacement)

    /// Fixed-size constraints for captures whose repository proof has not arrived yet.
    enum PreBindConstraint {
        case none
        case invalidate
        case requiresManualSelection
        case itemType(ItemType)
    }

    func preBindConstraint(for key: OfflineSnapshotKey) -> PreBindConstraint {
        switch self {
        case .none:
            return .none
        case .keys(let keys):
            return keys.contains(key) ? .invalidate : .none
        case .itemID(let itemID):
            return itemID == key.itemId ? .invalidate : .none
        case .all:
            return .invalidate
        case .vaultOnly(let vaultID):
            return vaultID == key.vaultId ? .requiresManualSelection : .none
        case .snapshot(let identity, _):
            return identity.key == key ? .invalidate : .none
        case .upsertItems(let items):
            return Self.constraint(for: key, incoming: items[key.itemId], absent: .none)
        case .replaceItems(let items):
            return Self.constraint(for: key, incoming: items[key.itemId], absent: .invalidate)
        case .retainVaults(let vaultIDs):
            return vaultIDs.contains(key.vaultId) ? .none : .invalidate
        case .reconcileSelections(let vaultIDs, let parents):
            return vaultIDs.contains(key.vaultId) && parents[key.itemId] == key.vaultId ? .none : .invalidate
        case .replaceMetadata(let replacement):
            guard replacement.vaultIDs.contains(key.vaultId) else { return .invalidate }
            // Decoded incoming items take precedence over lossy-list retention evidence.
            if let incoming = replacement.itemsByID[key.itemId] {
                return Self.constraint(for: key, incoming: incoming, absent: .invalidate)
            }
            let retained = replacement.presenceUncertainties.contains {
                $0.vaultID == key.vaultId && ($0.hasUnidentifiedSkippedItems || $0.skippedItemIDs.contains(key.itemId))
            }
            return retained ? .none : .invalidate
        }
    }

    func matches(_ proof: OfflineReleaseProof) -> Bool {
        if case .snapshot(let identity, let digest) = self {
            return proof.identity == identity && proof.ciphertextDigest == digest
        }
        switch preBindConstraint(for: proof.identity.key) {
        case .none: return false
        case .invalidate: return true
        case .requiresManualSelection: return !proof.isManuallySelected
        case .itemType(let type): return proof.itemType != type
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
    case committed(manualPromotions: [OfflineManualPromotion])
    case rolledBack
    case admissionFinished // Outer service intent owns no SQL outcome/events.
}

nonisolated struct OfflineMutationUpdate<Value: Sendable>: Sendable {
    let value: Value
    let manualPromotions: [OfflineManualPromotion]
}
