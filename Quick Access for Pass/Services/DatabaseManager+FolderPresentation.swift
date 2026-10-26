import Foundation
import GRDB

nonisolated extension DatabaseManager {
    /// One set-based read for a result batch, with one JSON-bound ID set rather than an unbounded IN list.
    func folderLocations(for itemIDs: Set<String>) throws -> [String: FolderLocationPresentation] {
        try reader.read { db in try Self.folderLocations(for: itemIDs, in: db) }
    }

    static func folderLocations(for itemIDs: Set<String>, in db: Database) throws -> [String: FolderLocationPresentation] {
        guard !itemIDs.isEmpty else { return [:] }
        guard let json = String(bytes: try JSONEncoder().encode(itemIDs.sorted()), encoding: .utf8) else {
            throw FolderCatalogError.incompleteEvidence
        }
        let rows = try Row.fetchAll(db, sql: folderLocationSQL, arguments: [json])
        var graph = FolderPresentationGraph()
        var memberships: [String: FolderPresentationGraph.FolderID] = [:]
        for row in rows {
            let kind: Int = row["recordKind"]
            guard let folderID: String = row["folderID"] else { continue }
            let id = FolderPresentationGraph.FolderID(vaultID: row["vaultID"], folderID: folderID)
            if kind == 0 {
                memberships[row["itemID"]] = id
            } else {
                graph.nodes[id] = FolderPresentationGraph.Node(id: id, name: row["name"], parentID: row["parentID"],
                    isSelected: false, policyGeneration: nil)
            }
        }
        return memberships.compactMapValues { graph.location(for: $0) }
    }

    /// Ancestor names are read once per needed node, not repeated once per item/ancestor pair.
    private static let folderLocationSQL = """
        WITH requestedFolderMemberships AS (
            SELECT fm.itemId, fm.vaultId, fm.folderId
            FROM folderItemMemberships fm
            JOIN items i ON i.id = fm.itemId AND i.vaultId = fm.vaultId
            JOIN json_each(?) requested ON requested.value = fm.itemId
            WHERE i.state = 'Active'
        ), requiredFolderIDs AS (
            SELECT DISTINCT fa.vaultId, fa.ancestorId AS folderId
            FROM requestedFolderMemberships m
            JOIN folderAncestors fa ON fa.vaultId = m.vaultId AND fa.folderId = m.folderId
        )
        SELECT 0 AS recordKind, m.itemId AS itemID, m.vaultId AS vaultID, m.folderId AS folderID,
               NULL AS name, NULL AS parentID
        FROM requestedFolderMemberships m
        UNION ALL
        SELECT 1, NULL, f.vaultId, f.id, f.name, f.parentId
        FROM folders f JOIN requiredFolderIDs n ON n.vaultId = f.vaultId AND n.folderId = f.id
        """
}
