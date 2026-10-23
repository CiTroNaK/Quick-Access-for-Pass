import Foundation

/// A metadata-only index into the caller-owned result, never a second plaintext backlog.
nonisolated struct OfflineSyncResultIndex: Sendable {
    var itemIndices: [OfflineSnapshotKey: Int] = [:]
    var sourceTimes: [String: Date] = [:]

    var contentRefreshCandidates: Set<OfflineSnapshotKey> = []

    init(_ result: CLISyncFetchResult) {
        var seenIDs: Set<String> = []
        var duplicateIDs: Set<String> = []
        var duplicateKeys: Set<OfflineSnapshotKey> = []
        for (index, member) in result.items.enumerated() {
            let key = OfflineSnapshotKey(vaultId: member.vaultId, itemId: member.item.id, schemaVersion: OfflineSnapshotLimits.schemaVersion)
            if itemIndices[key] != nil || duplicateKeys.contains(key) {
                itemIndices.removeValue(forKey: key)
                duplicateKeys.insert(key)
            } else { itemIndices[key] = index }
            if seenIDs.insert(member.item.id).inserted {
                sourceTimes[member.item.id] = OfflineSourceModificationTime.parse(member.item.modifyTime)
            } else {
                sourceTimes.removeValue(forKey: member.item.id)
                duplicateIDs.insert(member.item.id)
            }
        }
        let vaults = Dictionary(grouping: result.vaults, by: \.vaultId)
        // Presence is eligibility evidence only, never permission to reuse list content.
        for (key, position) in itemIndices where !duplicateIDs.contains(key.itemId) {
            let item = result.items[position].item
            guard item.vaultId == key.vaultId, let matchingVaults = vaults[key.vaultId], matchingVaults.count == 1,
                  matchingVaults[0].shareId == item.shareId else { continue }
            let policy = OfflineSnapshotContentPolicy.current
            let itemType = item.content.content.itemType
            guard policy.requiredRevision(for: itemType) > 0,
                  !policy.needsRefresh(contentRevision: policy.satisfiedRevision(for: item), for: itemType) else { continue }
            contentRefreshCandidates.insert(key)
        }
    }
}
