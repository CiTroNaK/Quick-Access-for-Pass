import Foundation

/// Committed presentation metadata, never fetch or secret-release authority.
nonisolated struct OfflineFolderSettingsRow: Sendable, Equatable, Identifiable {
    struct Identity: Sendable, Hashable {
        let vaultID: String
        let folderID: String
    }
    let vaultID: String
    let folderID: String
    let folderName: String
    let location: FolderLocationPresentation
    let isSelected: Bool
    let coveringAncestorID: String?
    let selectedCount: Int
    let usableCount: Int
    let lastRefreshedAt: Date?
    var id: Identity { Identity(vaultID: vaultID, folderID: folderID) }
    var path: String { location.path }
    var depth: Int { max(0, location.ancestorNames.count - 1) }
}

nonisolated enum OfflineFolderCatalogStatus: String, Sendable, Equatable {
    case fresh, deferred
}
