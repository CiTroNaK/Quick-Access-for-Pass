import Foundation

nonisolated enum CLIFolderCatalogParser {
    static func parse(_ data: Data, vault: CLIVault, memberships: [String: CLIFolderMembership]?,
                      stamp: FolderFeatureStamp) throws -> ValidatedFolderCatalog {
        guard data.count <= FolderCatalogLimits.maximumOutputBytes else { throw FolderCatalogError.limitExceeded }
        guard let memberships else { throw FolderCatalogError.incompleteEvidence }
        let rows = try JSONDecoder().decode([RawFolder].self, from: data)
        guard rows.count <= FolderCatalogLimits.maximumFolders else { throw FolderCatalogError.limitExceeded }
        let folders = try rows.map { row in
            guard row.shareID == vault.shareId,
                  !row.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FolderCatalogError.incompleteEvidence
            }
            return PassFolder(vaultID: vault.vaultId, id: row.id, name: row.content.name, parentID: row.parentID)
        }
        return try ValidatedFolderCatalog(vaultID: vault.vaultId, shareID: vault.shareId, folders: folders,
                                          itemMemberships: memberships, stamp: stamp)
    }
}

nonisolated private struct RawFolder: Decodable {
    let id: String
    let shareID: String
    let parentID: String?
    let content: Content

    struct Content: Decodable { let name: String }
    enum CodingKeys: String, CodingKey {
        case id, content
        case shareID = "share_id"
        case parentID = "parent_folder_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.parentID) else { throw FolderCatalogError.incompleteEvidence }
        id = try container.decode(String.self, forKey: .id)
        shareID = try container.decode(String.self, forKey: .shareID)
        parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        content = try container.decode(Content.self, forKey: .content)
    }
}
