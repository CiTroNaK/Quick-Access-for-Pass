/// Defensive application limits, not claimed restrictions of the upstream service.
nonisolated enum FolderCatalogLimits {
    static let maximumFolders = 10_000
    static let maximumDepth = 64
    static let maximumAncestryRows = 640_000
    static let maximumOutputBytes = 8 * 1024 * 1024
}

nonisolated enum FolderCatalogError: Error {
    case incompleteEvidence
    case invalidGraph
    case limitExceeded
}

/// Validated immutable metadata only. It never retains CLI items, secrets, or payload bytes.
nonisolated struct ValidatedFolderCatalog: Sendable {
    let vaultID: String
    let shareID: String
    let folders: [PassFolder]
    let itemMemberships: [String: CLIFolderMembership]
    let stamp: FolderFeatureStamp
    let ancestors: [FolderAncestor]

    init(vaultID: String, shareID: String, folders: [PassFolder],
         itemMemberships: [String: CLIFolderMembership], stamp: FolderFeatureStamp) throws {
        guard !vaultID.isEmpty, !shareID.isEmpty else { throw FolderCatalogError.incompleteEvidence }
        guard folders.count <= FolderCatalogLimits.maximumFolders else { throw FolderCatalogError.limitExceeded }
        let byID = try Self.indexFolders(folders, vaultID: vaultID)
        let rowCount = try Self.validateTopology(folders, byID: byID)
        try Self.validateMemberships(itemMemberships, byID: byID)
        let ancestors = Self.ancestorRows(folders, byID: byID, rowCount: rowCount)
        self.vaultID = vaultID
        self.shareID = shareID
        self.folders = folders
        self.itemMemberships = itemMemberships
        self.stamp = stamp
        self.ancestors = ancestors
    }

    private static func indexFolders(_ folders: [PassFolder], vaultID: String) throws -> [String: PassFolder] {
        var byID: [String: PassFolder] = [:]
        for folder in folders {
            guard folder.vaultID == vaultID, !folder.id.isEmpty,
                  byID.updateValue(folder, forKey: folder.id) == nil else { throw FolderCatalogError.invalidGraph }
        }
        return byID
    }

    private static func validateTopology(_ folders: [PassFolder], byID: [String: PassFolder]) throws -> Int {
        var children: [String: [String]] = [:]
        var queue: [(id: String, level: Int)] = []
        for folder in folders {
            if let parent = folder.parentID {
                guard byID[parent] != nil else { throw FolderCatalogError.invalidGraph }
                children[parent, default: []].append(folder.id)
            } else {
                queue.append((folder.id, 1))
            }
        }
        // Validate the entire graph and checked closure budget before materializing rows.
        var offset = 0
        var rowCount = 0
        while offset < queue.count {
            let node = queue[offset]
            guard node.level <= FolderCatalogLimits.maximumDepth else { throw FolderCatalogError.limitExceeded }
            let sum = rowCount.addingReportingOverflow(node.level)
            guard !sum.overflow, sum.partialValue <= FolderCatalogLimits.maximumAncestryRows else {
                throw FolderCatalogError.limitExceeded
            }
            rowCount = sum.partialValue
            for child in children[node.id, default: []] { queue.append((child, node.level + 1)) }
            offset += 1
        }
        // Every node has exactly one parent; unreachable nodes must belong to a cycle.
        guard queue.count == folders.count else { throw FolderCatalogError.invalidGraph }
        return rowCount
    }

    private static func validateMemberships(_ memberships: [String: CLIFolderMembership], byID: [String: PassFolder]) throws {
        for (itemID, membership) in memberships {
            guard !itemID.isEmpty else { throw FolderCatalogError.incompleteEvidence }
            switch membership {
            case .root: break
            case .folder(let id):
                guard byID[id] != nil else { throw FolderCatalogError.incompleteEvidence }
            case .unknown: throw FolderCatalogError.incompleteEvidence
            }
        }
    }

    private static func ancestorRows(_ folders: [PassFolder], byID: [String: PassFolder], rowCount: Int) -> [FolderAncestor] {
        var ancestors: [FolderAncestor] = []
        ancestors.reserveCapacity(rowCount)
        for folder in folders {
            var ancestor: String? = folder.id
            var depth = 0
            while let id = ancestor {
                ancestors.append(FolderAncestor(folderID: folder.id, ancestorID: id, depth: depth))
                ancestor = byID[id]?.parentID
                depth += 1
            }
        }
        return ancestors
    }
}

nonisolated enum FolderCatalogFetchOutcome: Sendable {
    case unsupported
    case unavailable
    case complete(ValidatedFolderCatalog)
}
