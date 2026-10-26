import Foundation
/// SQL predicates shared by repository reads and publication authorization.
nonisolated enum OfflineSelectionSQL {
    enum ItemReference {
        case selection, item, bound
        var itemID: String {
            switch self {
            case .selection: "o.itemId"
            case .item: "i.id"
            case .bound: "?"
            }
        }
        var vaultID: String {
            switch self {
            case .selection: "o.vaultId"
            case .item: "i.vaultId"
            case .bound: "?"
            }
        }
    }

    // Only these closed, internal column references are interpolated. IDs remain bound arguments.
    static func folderPolicyRows(for item: ItemReference) -> String {
        """
        FROM folderItemMemberships fm
        JOIN folderAncestors fa ON fa.vaultId = fm.vaultId AND fa.folderId = fm.folderId
        JOIN offlineFolders fs ON fs.vaultId = fa.vaultId AND fs.folderId = fa.ancestorId
        WHERE fm.itemId = \(item.itemID) AND fm.vaultId = \(item.vaultID)
        """
    }

    static func folderCoverage(for item: ItemReference, excludingFolder: Bool = false) -> String {
        "EXISTS(SELECT 1 \(folderPolicyRows(for: item)) \(excludingFolder ? "AND fs.folderId != ?" : ""))"
    }

    enum FolderPolicyField { case id, generation }
    static func nearestFolderPolicy(_ field: FolderPolicyField) -> String {
        let column = field == .id ? "fs.folderId" : "fs.policyGeneration"
        return "(SELECT \(column) \(folderPolicyRows(for: .item)) ORDER BY fa.depth, fs.folderId LIMIT 1)"
    }

    static func automaticCoverage(for item: ItemReference, excludingVault: Bool = false,
                                  excludingFolder: Bool = false) -> String {
        let vault = excludingVault ? "0" : "EXISTS(SELECT 1 FROM offlineVaults vsel WHERE vsel.vaultId = \(item.vaultID))"
        return "(\(vault) OR \(folderCoverage(for: item, excludingFolder: excludingFolder)))"
    }

    static let effectiveSelection = """
    (o.isManuallySelected = 1 OR (
      \(automaticCoverage(for: .selection))
      AND NOT EXISTS(SELECT 1 FROM offlineItemExclusions x WHERE x.itemId = o.itemId AND x.vaultId = o.vaultId)
    ))
    """
}
