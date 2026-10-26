/// Display-only location. Never parse names or separators back into authorization identities.
nonisolated struct FolderLocationPresentation: Sendable, Equatable {
    let folderID: String
    let ancestorNames: [String]
    var path: String { ancestorNames.joined(separator: " / ") }
}

typealias FolderLocationLoader = @Sendable (Set<String>) async throws -> [String: FolderLocationPresentation]
