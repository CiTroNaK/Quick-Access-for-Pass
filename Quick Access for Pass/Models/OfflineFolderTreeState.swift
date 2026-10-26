import Foundation

/// Disclosure and local filtering only. Visibility and inherited checkmarks grant no selection authority.
nonisolated struct OfflineFolderTreeState {
    private(set) var collapsed: Set<OfflineFolderSettingsRow.ID> = []

    mutating func toggleExpansion(_ id: OfflineFolderSettingsRow.ID) {
        if !collapsed.insert(id).inserted { collapsed.remove(id) }
    }

    func visibleRows(_ rows: [OfflineFolderSettingsRow], availability: FolderFeatureAvailability,
                     matching query: String = "", selectedOnly: Bool = false, vaultSelected: Bool = false) -> [OfflineFolderSettingsRow] {
        // Capability loss must not strand removal behind a stale query or collapsed branch.
        guard availability == .supported else { return rows.filter(\.isSelected) }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty || selectedOnly {
            var included: Set<OfflineFolderSettingsRow.ID> = []
            var ancestors: [OfflineFolderSettingsRow] = []
            for row in rows {
                if ancestors.first?.vaultID != row.vaultID { ancestors.removeAll(keepingCapacity: true) }
                while let parent = ancestors.last, parent.depth >= row.depth { ancestors.removeLast() }
                let matches = query.isEmpty || row.path.localizedStandardContains(query)
                let covered = row.isSelected || Self.isInheritedOnly(row, vaultSelected: vaultSelected)
                if matches && (!selectedOnly || covered) {
                    included.insert(row.id)
                    for ancestor in ancestors { included.insert(ancestor.id) }
                }
                ancestors.append(row)
            }
            // Keep context unchanged: an unselected ancestor is not a newly selected policy.
            return rows.filter { included.contains($0.id) }
        }
        var result: [OfflineFolderSettingsRow] = []
        var hidden: (vaultID: String, depth: Int)?
        for row in rows {
            if let hidden, hidden.vaultID == row.vaultID, row.depth > hidden.depth { continue }
            hidden = nil
            result.append(row)
            if collapsed.contains(row.id) { hidden = (row.vaultID, row.depth) }
        }
        return result
    }

    static func branchIDs(_ rows: [OfflineFolderSettingsRow]) -> Set<OfflineFolderSettingsRow.ID> {
        Set(zip(rows, rows.dropFirst()).compactMap { current, next in
            current.vaultID == next.vaultID && next.depth > current.depth ? current.id : nil
        })
    }

    static func isInheritedOnly(_ row: OfflineFolderSettingsRow, vaultSelected: Bool) -> Bool {
        !row.isSelected && (row.coveringAncestorID != nil || vaultSelected)
    }
}
