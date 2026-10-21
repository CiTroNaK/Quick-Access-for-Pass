import Foundation
/// SQL predicates shared by repository reads and publication authorization.
nonisolated enum OfflineSelectionSQL {
    static let effectiveSelection = """
    (o.isManuallySelected = 1 OR (
      EXISTS(SELECT 1 FROM offlineVaults vsel WHERE vsel.vaultId = o.vaultId)
      AND NOT EXISTS(SELECT 1 FROM offlineItemExclusions x WHERE x.itemId = o.itemId AND x.vaultId = o.vaultId)
    ))
    """
}
