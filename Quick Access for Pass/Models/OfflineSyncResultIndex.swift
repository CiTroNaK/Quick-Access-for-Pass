import Foundation

/// A metadata-only index into the caller-owned result, never a second plaintext backlog.
nonisolated struct OfflineSyncResultIndex: Sendable {
    var itemIndices: [OfflineSnapshotKey: Int] = [:]
    var sourceTimes: [String: Date] = [:]

    init(_ result: CLISyncFetchResult) {
        var seenIDs: Set<String> = []
        var duplicateKeys: Set<OfflineSnapshotKey> = []
        for (index, member) in result.items.enumerated() {
            let key = OfflineSnapshotKey(vaultId: member.vaultId, itemId: member.item.id, schemaVersion: OfflineSnapshotLimits.schemaVersion)
            if itemIndices[key] != nil || duplicateKeys.contains(key) {
                itemIndices.removeValue(forKey: key)
                duplicateKeys.insert(key)
            } else { itemIndices[key] = index }
            if seenIDs.insert(member.item.id).inserted {
                sourceTimes[member.item.id] = OfflineSourceModificationTime.parse(member.item.modifyTime)
            } else { sourceTimes.removeValue(forKey: member.item.id) }
        }
    }
}
