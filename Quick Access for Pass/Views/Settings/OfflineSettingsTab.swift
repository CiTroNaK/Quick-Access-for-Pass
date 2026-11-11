import SwiftUI

struct OfflineSettingsTab: View {
    private enum ManagerSheet: Hashable, Identifiable {
        case items
        case folders(vaultID: String)
        var id: Self { self }
    }

    @Environment(\.offlineModeCoordinator) private var coordinator
    @Environment(\.locale) private var locale
    @State private var isRemoveAllConfirmationPresented = false
    @State private var activeManager: ManagerSheet?
    @State private var errorMessage: String?

    var body: some View {
        SettingsLayout.settingsPane {
            if let coordinator {
                offlineVaultSection(coordinator)
                Divider()
                selectedOfflineItemsSection(coordinator)
                Divider()
                destructiveActionsSection(coordinator)
            } else {
                Text("Offline settings are unavailable.")
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(item: $activeManager) { manager in
            if let coordinator {
                switch manager {
                case .items:
                    OfflineItemsManagerView(coordinator: coordinator)
                case .folders(let vaultID):
                    OfflineFoldersManagerView(coordinator: coordinator, initialVaultID: vaultID)
                }
            }
        }
        .onChange(of: coordinator?.observationErrorMessage) { _, message in
            guard message != nil else { return }
            AccessibilityNotification.Announcement(
                String(localized: "Offline status updates are unavailable. Use Retry offline status to try again.")
            ).post()
        }
        .confirmationDialog(
            "Remove all offline data?",
            isPresented: $isRemoveAllConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Remove all offline data", role: .destructive) {
                Task { await removeAllOfflineData() }
            }
            .disabled(!(coordinator?.canPurge ?? false))
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all device-bound offline copies and their selections.")
        }
    }

    @ViewBuilder
    private func offlineVaultSection(_ coordinator: OfflineModeCoordinator) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Offline vaults and folders")
                .font(.body)
            Text("Choose whole vaults, folders, or individual items to keep offline.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("How offline access works") {
                VStack(alignment: .leading, spacing: 8) {
                    offlineSelectionExplanation
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
            if let message = FolderSettingsLocalization.capabilityMessage(coordinator.folderPresentationAvailability, locale: locale) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if coordinator.requiresInitializationRetry {
                Text("Offline access could not be initialized. Live access and removal remain available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Retry offline setup") {
                    Task { await retryOfflineInitialization() }
                }
                .disabled(coordinator.isPerformingTask)
            } else if let observationErrorMessage = coordinator.observationErrorMessage {
                Text(observationErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(observationErrorMessage)
                Button("Retry offline status") {
                    retryOfflineStatus()
                }
                .disabled(coordinator.isPerformingTask)
                .accessibilityHint("Restarts offline status updates")
            }
            if coordinator.vaults.isEmpty {
                Text("No vaults are available.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(coordinator.vaults) { vault in
                    vaultSelectionRow(vault, coordinator: coordinator)
                }
            }
        }
    }

    private func vaultSelectionRow(_ vault: OfflineVaultSettingsRow, coordinator: OfflineModeCoordinator) -> some View {
        let folderCount = (coordinator.folderRowsByVaultID[vault.id] ?? []).filter(\.isSelected).count
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: vault.vaultName)
                    .lineLimit(1).truncationMode(.middle).help(vault.vaultName)
                Text(FolderSettingsLocalization.folderSelections(count: folderCount, locale: locale))
                    .font(.caption).foregroundStyle(.secondary)
                Text(FolderSettingsLocalization.counts(selected: vault.selectedCount, usable: vault.usableCount, locale: locale))
                    .font(.caption2).foregroundStyle(.secondary)
                    .help(vaultStatus(for: vault))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if coordinator.hasFolders(in: vault.id) {
                Button("Manage folders…") { activeManager = .folders(vaultID: vault.id) }
                    .disabled(coordinator.folderPresentationAvailability != .supported && folderCount == 0)
                    .accessibilityHint(FolderSettingsLocalization.text("Manage offline folders in \(vault.vaultName)", locale: locale))
                    .fixedSize()
            }
            Toggle(vault.vaultName, isOn: Binding(
                get: { vault.isSelected },
                set: { selected in Task { await selectWholeVault(selected, vaultID: vault.id) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .fixedSize()
            .disabled((!vault.isSelected && !coordinator.canMakeNewSelections)
                || (vault.isSelected && !coordinator.canDeselectVault(vault.id)))
            .accessibilityValue(vaultStatus(for: vault))
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private var offlineSelectionExplanation: some View {
        Group {
            Text("Selecting a folder includes subfolders and future items after a complete sync. Turning it off keeps independent selections.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("""
                Selecting a vault stores encrypted offline copies of all its items on this Mac. \
                New items added to selected vaults will also become available offline after syncing.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Text("Items removed individually stay excluded until selected again. Turning off a vault keeps individually selected items.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Text("""
                Items and vaults enabled for Offline Mode use cached values when a usable copy is available. \
                Sync is needed to refresh them. \
                Without a usable cached copy, Quick Access uses Pass CLI.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Text("""
                Offline copies are used for copy actions, Large Type, and System AutoFill. \
                SSH Agent and Run proxies do not use offline copies.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func selectedOfflineItemsSection(_ coordinator: OfflineModeCoordinator) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Selected offline items")
                .font(.body)
            if coordinator.itemGroups.isEmpty {
                Text("No items are selected for offline access.")
                    .foregroundStyle(.secondary)
            } else {
                let selectedCount = coordinator.vaults.reduce(0) { $0 + $1.selectedCount }
                let usableCount = coordinator.vaults.reduce(0) { $0 + $1.usableCount }
                Text("\(selectedCount) selected, \(usableCount) usable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Manage offline items…") {
                activeManager = .items
            }
        }
    }

    @ViewBuilder
    private func destructiveActionsSection(_ coordinator: OfflineModeCoordinator) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Destructive actions")
                .font(.body)
            Button("Remove all offline data", role: .destructive) {
                isRemoveAllConfirmationPresented = true
            }
            .disabled(Self.isPurgeDisabled(coordinator))
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel(errorMessage)
            }
        }
    }

    static func isPurgeDisabled(_ coordinator: OfflineModeCoordinator) -> Bool {
        !coordinator.canPurge
    }

    private func retryOfflineInitialization() async {
        guard let coordinator else { return }
        do {
            try await coordinator.retryInitialization()
            errorMessage = nil
        } catch {
            publishError(String(localized: "Could not initialize offline access. Try again."))
        }
    }

    private func retryOfflineStatus() {
        coordinator?.retryObservation()
    }

    private func publishError(_ message: String) {
        errorMessage = message
        AccessibilityNotification.Announcement(message).post()
    }

    private func selectWholeVault(_ selected: Bool, vaultID: String) async {
        guard let coordinator else { return }
        do {
            try await coordinator.selectWholeVault(selected, vaultID: vaultID)
            errorMessage = nil
        } catch {
            publishError(String(localized: "Could not update offline vault settings. Try again."))
        }
    }

    private func removeAllOfflineData() async {
        guard let coordinator else { return }
        do {
            try await coordinator.removeAllOfflineData()
            errorMessage = nil
            AccessibilityNotification.Announcement(String(localized: "All offline data removed.")).post()
        } catch {
            publishError(String(localized: "Could not remove offline data. Try again."))
        }
    }

}

private extension OfflineSettingsTab {
    func vaultStatus(for vault: OfflineVaultSettingsRow) -> String {
        guard let lastRefreshedAt = vault.lastRefreshedAt else {
            return FolderSettingsLocalization.counts(selected: vault.selectedCount, usable: vault.usableCount, locale: locale)
        }
        let timestamp = lastRefreshedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale))
        var status = LocalizedStringResource.offlineVaultLastRefreshedStatus(vault.selectedCount, vault.usableCount, timestamp)
        status.locale = locale
        return String(localized: status)
    }

}
