/// Stable metadata identity; names and separators are display-only and remain verbatim.
nonisolated struct PassFolder: Sendable, Equatable {
    let vaultID: String
    let id: String
    let name: String
    let parentID: String?
}

nonisolated enum CLIFolderMembership: Sendable, Equatable {
    case root
    case folder(String)
    case unknown
}

nonisolated struct FolderAncestor: Sendable, Equatable {
    let folderID: String
    let ancestorID: String
    /// Self is zero; the direct parent is one.
    let depth: Int
}
