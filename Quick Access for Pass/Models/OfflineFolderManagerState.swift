import Foundation

/// Memory-only presentation state; never evidence for selection, fetch, or release authority.
nonisolated struct OfflineFolderManagerState: Sendable {
    private(set) var selectedVaultID: String
    var query = ""
    var selectedOnly = false
    var tree = OfflineFolderTreeState()
    private var isVisible = false
    private var feedbackID = UUID()

    init(initialVaultID: String) { selectedVaultID = initialVaultID }

    mutating func selectVault(_ vaultID: String) {
        guard vaultID != selectedVaultID else { return }
        selectedVaultID = vaultID
        query = ""
        selectedOnly = false
        tree = OfflineFolderTreeState()
        feedbackID = UUID()
    }

    mutating func updateAvailability(_ availability: FolderFeatureAvailability) {
        feedbackID = UUID()
        if availability != .supported {
            query = ""
            selectedOnly = false
        }
    }

    mutating func setVisible(_ visible: Bool) {
        isVisible = visible
        feedbackID = UUID()
    }

    /// Nil suppresses presentation only; it must never cancel or undo service-owned work.
    mutating func beginFeedback(forVaultID vaultID: String) -> UUID? {
        guard isVisible, vaultID == selectedVaultID else { return nil }
        feedbackID = UUID()
        return feedbackID
    }

    func isFeedbackCurrent(_ token: UUID?, vaultID: String) -> Bool {
        isVisible && token == feedbackID && vaultID == selectedVaultID
    }

    func selectedVault(in vaults: [OfflineVaultSettingsRow]) -> OfflineVaultSettingsRow? {
        vaults.first { $0.id == selectedVaultID }
    }

    func visibleRows(vaults: [OfflineVaultSettingsRow], rowsByVaultID: [String: [OfflineFolderSettingsRow]],
                     availability: FolderFeatureAvailability) -> [OfflineFolderSettingsRow] {
        guard let vault = selectedVault(in: vaults) else { return [] }
        return tree.visibleRows(rowsByVaultID[selectedVaultID] ?? [], availability: availability,
                                matching: query, selectedOnly: selectedOnly, vaultSelected: vault.isSelected)
    }
}
