import Foundation
import GRDB

/// A single metadata-only read shared by folder rows and per-item policy presentation.
nonisolated struct OfflineFolderPresentation {
    private var graph = FolderPresentationGraph()
    private var memberships: [String: FolderPresentationGraph.FolderID] = [:]
    private(set) var statusesByVaultID: [String: OfflineFolderCatalogStatus] = [:]
    private(set) var stampsByVaultID: [String: FolderFeatureStamp] = [:]

    static func read(in db: Database) throws -> Self {
        var result = Self()
        for row in try Row.fetchAll(db, sql: metadataSQL) {
            let kind: Int = row["recordKind"]
            let vaultID: String = row["vaultID"]
            if kind == 2 {
                let status: String = row["status"]
                result.statusesByVaultID[vaultID] = OfflineFolderCatalogStatus(rawValue: status) ?? .deferred
                let selection: String? = row["catalogSelectionGeneration"]
                let probe: String? = row["catalogProbeRevision"]
                if status == "fresh", let selection = selection.flatMap(UUID.init(uuidString:)),
                   let probe = probe.flatMap(UUID.init(uuidString:)) {
                    result.stampsByVaultID[vaultID] = FolderFeatureStamp(selectionGeneration: selection, probeRevision: probe)
                }
                continue
            }
            guard let folderID: String = row["folderID"] else { continue }
            let id = FolderPresentationGraph.FolderID(vaultID: vaultID, folderID: folderID)
            if kind == 1 {
                result.memberships[row["itemID"]] = id
            } else {
                let policy: String? = row["policyGeneration"]
                result.graph.nodes[id] = FolderPresentationGraph.Node(id: id, name: row["name"], parentID: row["parentID"],
                    isSelected: policy != nil, policyGeneration: policy.flatMap(UUID.init(uuidString:)))
            }
        }
        return result
    }

    var locationsByItemID: [String: FolderLocationPresentation] {
        memberships.compactMapValues { graph.location(for: $0) }
    }

    func policies(for itemID: String) -> [OfflineFolderSelection] {
        memberships[itemID].map { graph.policies(for: $0) } ?? []
    }

    func settingsRows(items: [OfflineItemSettingsRow]) -> [String: [OfflineFolderSettingsRow]] {
        var counts: [FolderPresentationGraph.FolderID: Counts] = [:]
        for item in items {
            guard let leaf = memberships[item.itemId], leaf.vaultID == item.vaultId,
                  let ancestors = graph.ancestorIDs(for: leaf) else { continue }
            // Each item has one leaf and each ancestor appears once, independently of overlapping policies.
            for id in ancestors {
                counts[id, default: Counts()].selected += 1
                if item.hasUsableSnapshot { counts[id, default: Counts()].usable += 1 }
                if let time = item.lastRefreshedAt, counts[id]?.lastRefreshedAt.map({ $0 < time }) ?? true {
                    counts[id, default: Counts()].lastRefreshedAt = time
                }
            }
        }
        var result = Dictionary(uniqueKeysWithValues: statusesByVaultID.keys.map { ($0, [OfflineFolderSettingsRow]()) })
        for id in graph.orderedIDs() {
            guard let node = graph.nodes[id], let location = graph.location(for: id),
                  let ancestors = graph.ancestorIDs(for: id) else { continue }
            let covering = ancestors.dropLast().reversed().first { graph.nodes[$0]?.isSelected == true }
            let count = counts[id] ?? Counts()
            result[id.vaultID, default: []].append(OfflineFolderSettingsRow(vaultID: id.vaultID, folderID: id.folderID,
                folderName: node.name, location: location, isSelected: node.isSelected, coveringAncestorID: covering?.folderID,
                selectedCount: count.selected, usableCount: count.usable, lastRefreshedAt: count.lastRefreshedAt))
        }
        return result
    }

    private struct Counts {
        var selected = 0
        var usable = 0
        var lastRefreshedAt: Date?
    }

    private static let metadataSQL = """
        SELECT 0 AS recordKind, f.vaultId AS vaultID, f.id AS folderID, f.name, f.parentId AS parentID,
               p.policyGeneration, NULL AS itemID, NULL AS status,
               NULL AS catalogSelectionGeneration, NULL AS catalogProbeRevision
        FROM folders f LEFT JOIN offlineFolders p ON p.vaultId = f.vaultId AND p.folderId = f.id
        UNION ALL
        SELECT 1, fm.vaultId, fm.folderId, NULL, NULL, NULL, fm.itemId, NULL, NULL, NULL
        FROM folderItemMemberships fm
        JOIN offlineItems o ON o.itemId = fm.itemId AND o.vaultId = fm.vaultId
        JOIN items i ON i.id = o.itemId AND i.vaultId = o.vaultId
        WHERE i.state = 'Active' AND (\(OfflineSelectionSQL.effectiveSelection))
        UNION ALL
        SELECT 2, vaultId, NULL, NULL, NULL, NULL, NULL, reconciliationStatus, selectionGeneration, probeRevision
        FROM folderCatalogState
        """
}
