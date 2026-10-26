import SwiftUI

/// Committed folder metadata only. All mutations still pass through the shared coordinator.
@MainActor
struct OfflineFoldersManagerView: View {
    let coordinator: OfflineModeCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var manager: OfflineFolderManagerState
    @State private var errorMessage: String?
    @FocusState private var isFilterFocused: Bool

    init(coordinator: OfflineModeCoordinator, initialVaultID: String) {
        self.coordinator = coordinator
        _manager = State(initialValue: OfflineFolderManagerState(initialVaultID: initialVaultID))
    }

    private var vaultID: String { manager.selectedVaultID }

    var body: some View {
        let vault = manager.selectedVault(in: coordinator.vaults)
        let rows = vault == nil ? [] : coordinator.folderRowsByVaultID[vaultID] ?? []
        let availability = coordinator.folderPresentationAvailability
        let visible = manager.visibleRows(vaults: coordinator.vaults, rowsByVaultID: coordinator.folderRowsByVaultID,
                                          availability: availability)
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose folders to keep offline").font(.headline)
            Text("Selecting a folder includes subfolders and future items after a complete sync. Turning it off keeps independent selections.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Picker("Vault", selection: Binding(get: { manager.selectedVaultID }, set: {
                    manager.selectVault($0)
                    errorMessage = nil
                })) {
                    if vault == nil {
                        Text("This vault is no longer available.").tag(vaultID)
                    } else if !coordinator.hasFolders(in: vaultID) {
                        // Keep the current identity without guessing an empty catalog or silently choosing another.
                        if coordinator.folderDiscoveryIsCurrent(vaultID: vaultID) {
                            Text("No folders in this vault.").tag(vaultID)
                        } else {
                            Text("Unavailable").tag(vaultID)
                        }
                    }
                    ForEach(coordinator.vaults.filter { coordinator.hasFolders(in: $0.id) }) { vault in
                        Text(verbatim: vault.vaultName).tag(vault.id)
                    }
                }
                .frame(width: 200)
                TextField("Filter folders", text: $manager.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFilterFocused)
                    .disabled(availability != .supported || vault == nil)
                Toggle("Selected only", isOn: $manager.selectedOnly)
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    .disabled(availability != .supported || vault == nil)
            }
            if let message = FolderSettingsLocalization.capabilityMessage(availability, locale: locale) {
                statusText(message)
            }
            if coordinator.observationErrorMessage != nil {
                Text("Offline status could not be updated. Retry offline setup.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry offline status") { coordinator.retryObservation() }
                    .disabled(coordinator.isPerformingTask)
            }
            if vault != nil && availability == .supported && !coordinator.folderDiscoveryIsCurrent(vaultID: vaultID) {
                Text("Folder data is unavailable. Sync with Pass CLI 2.5.0 or newer to select folders.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            folderRegion(vault: vault, rows: rows, visible: visible, availability: availability)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let errorMessage {
                Text(verbatim: errorMessage).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Text(FolderSettingsLocalization.foldersShown(count: visible.count, locale: locale))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(FolderSettingsLocalization.folderSelections(count: rows.filter(\.isSelected).count, locale: locale))
                    .font(.caption).foregroundStyle(.secondary)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 480)
        .onAppear {
            manager.setVisible(true)
            isFilterFocused = availability == .supported
        }
        .onDisappear { manager.setVisible(false) }
        .onChange(of: availability) { _, availability in
            manager.updateAvailability(availability)
            errorMessage = nil
        }
    }

    @ViewBuilder
    private func folderRegion(vault: OfflineVaultSettingsRow?, rows: [OfflineFolderSettingsRow],
                              visible: [OfflineFolderSettingsRow], availability: FolderFeatureAvailability) -> some View {
        if let vault {
            if visible.isEmpty {
                if rows.isEmpty && availability == .supported && coordinator.folderDiscoveryIsCurrent(vaultID: vaultID) {
                    Text("No folders in this vault.").foregroundStyle(.secondary)
                } else if availability != .supported {
                    Text("No selected folders in this vault.").foregroundStyle(.secondary)
                } else if rows.isEmpty {
                    // The readiness warning above describes failed/deferred discovery, not an empty catalog.
                    Color.clear.accessibilityHidden(true)
                } else {
                    Text("No matching folders.").foregroundStyle(.secondary)
                }
            } else {
                ScrollView {
                    OfflineFolderTreeView(rows: rows, availability: availability, vaultSelected: vault.isSelected,
                        canSelect: { coordinator.canSelectFolder(folderID: $0.folderID, vaultID: $0.vaultID) },
                        canDeselect: { coordinator.canDeselectFolder(folderID: $0.folderID, vaultID: $0.vaultID) },
                        onSelectionChange: { selected, row in
                            // Button tasks outlive presentation; the coordinator/service retain actual work ownership.
                            Task { await selectFolder(selected, row: row) }
                        }, matching: manager.query, selectedOnly: manager.selectedOnly, treeState: $manager.tree)
                        .padding(12)
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
            }
        } else {
            Text("This vault is no longer available.").foregroundStyle(.secondary)
        }
    }

    private func statusText(_ text: String) -> some View {
        Text(verbatim: text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func selectFolder(_ selected: Bool, row: OfflineFolderSettingsRow) async {
        guard vaultID == row.vaultID, coordinator.vaults.contains(where: { $0.id == row.vaultID }) else { return }
        let feedback = manager.beginFeedback(forVaultID: row.vaultID)
        if feedback != nil { errorMessage = nil }
        do {
            try await coordinator.setFolderSelected(selected, folderID: row.folderID, vaultID: row.vaultID)
            guard manager.isFeedbackCurrent(feedback, vaultID: row.vaultID) else { return }
            errorMessage = nil
            AccessibilityNotification.Announcement(
                FolderSettingsLocalization.text("Folder selection updated.", locale: locale)
            ).post()
        } catch {
            guard manager.isFeedbackCurrent(feedback, vaultID: row.vaultID) else { return }
            let message = FolderSettingsLocalization.text("Could not update offline folder settings. Sync and try again.", locale: locale)
            errorMessage = message
            AccessibilityNotification.Announcement(message).post()
        }
    }
}
