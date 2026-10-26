import Foundation

/// Bounded, metadata-only path projection. Missing parents/cycles never become guessed roots.
nonisolated struct FolderPresentationGraph {
    typealias FolderID = OfflineFolderSettingsRow.ID
    struct Node {
        let id: FolderID
        let name: String
        let parentID: String?
        let isSelected: Bool
        let policyGeneration: UUID?
    }
    var nodes: [FolderID: Node] = [:]

    func ancestorIDs(for id: FolderID) -> [FolderID]? {
        var chain: [FolderID] = []
        var visited: Set<FolderID> = []
        var current: FolderID? = id
        while let value = current {
            guard chain.count < FolderCatalogLimits.maximumDepth, visited.insert(value).inserted,
                  let node = nodes[value] else { return nil }
            chain.append(value)
            current = node.parentID.map { FolderID(vaultID: value.vaultID, folderID: $0) }
        }
        return chain.reversed()
    }

    func location(for id: FolderID) -> FolderLocationPresentation? {
        guard let ancestors = ancestorIDs(for: id) else { return nil }
        return FolderLocationPresentation(folderID: id.folderID, ancestorNames: ancestors.compactMap { nodes[$0]?.name })
    }

    func policies(for id: FolderID) -> [OfflineFolderSelection] {
        guard let ancestors = ancestorIDs(for: id) else { return [] }
        return ancestors.reversed().compactMap { value in
            guard let generation = nodes[value]?.policyGeneration else { return nil }
            return OfflineFolderSelection(vaultID: value.vaultID, folderID: value.folderID, generation: generation)
        }
    }

    func orderedIDs() -> [FolderID] {
        let children = Dictionary(grouping: nodes.values, by: { node in
            node.parentID.map { FolderID(vaultID: node.id.vaultID, folderID: $0) }
        }).mapValues { $0.sorted(by: Self.ordersNodes).map(\.id) }
        var pending = Array((children[nil] ?? []).reversed())
        var visited: Set<FolderID> = []
        var result: [FolderID] = []
        while let id = pending.popLast() {
            guard visited.insert(id).inserted, ancestorIDs(for: id) != nil else { continue }
            result.append(id)
            pending.append(contentsOf: (children[id] ?? []).reversed())
        }
        return result
    }

    private static func ordersNodes(_ lhs: Node, _ rhs: Node) -> Bool {
        if lhs.id.vaultID != rhs.id.vaultID { return lhs.id.vaultID < rhs.id.vaultID }
        let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        return comparison == .orderedSame ? lhs.id.folderID < rhs.id.folderID : comparison == .orderedAscending
    }
}
