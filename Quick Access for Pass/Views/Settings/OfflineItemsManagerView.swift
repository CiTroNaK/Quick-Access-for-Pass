import SwiftUI

/// Presents committed catalog metadata only; browsing and searching never loads a secret.
struct OfflineItemsManagerView: View {
    let coordinator: OfflineModeCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var isVisible = false

    var body: some View {
        let groups = Self.filteredGroups(coordinator.itemGroups, matching: searchText)
        VStack(alignment: .leading, spacing: 12) {
            Text("Selected offline items")
                .font(.body)
            TextField("Search items or vaults", text: $searchText)
                .textFieldStyle(.roundedBorder)
            if let message = coordinator.observationErrorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry offline status") { coordinator.retryObservation() }
                    .disabled(coordinator.isPerformingTask)
            }
            if groups.isEmpty {
                Text(coordinator.itemGroups.isEmpty
                     ? String(localized: "No items are selected for offline access.")
                     : String(localized: "No matching offline items."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                List {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.items) { item in
                                itemRow(item)
                            }
                        } header: {
                            Text("\(group.vaultName) · \(group.items.count)")
                                .font(.body)
                                .fontWeight(.regular)
                        }
                    }
                }
                .listStyle(.inset)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("\(groups.reduce(0) { $0 + $1.items.count }) items shown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 480)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }

    /// Search only titles, types, vault names, and account identifiers in the metadata projection.
    static func filteredGroups(_ groups: [OfflineItemSettingsGroup], matching query: String) -> [OfflineItemSettingsGroup] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groups }
        return groups.compactMap { group in
            let matchesVault = group.vaultName.localizedStandardContains(query)
            let items = group.items.filter {
                matchesVault || $0.title.localizedStandardContains(query)
                    || $0.itemType.displayName.localizedStandardContains(query)
                    || (accountIdentifier(for: $0.item)?.localizedStandardContains(query) ?? false)
            }
            guard !items.isEmpty else { return nil }
            return OfflineItemSettingsGroup(vaultId: group.vaultId, vaultName: group.vaultName, items: items)
        }
    }

    /// Other item subtitles can be cardholder names or SSIDs, not account identifiers.
    static func accountIdentifier(for item: PassItem) -> String? {
        guard item.itemType == .login || item.itemType == .identity else { return nil }
        let identifier = item.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return identifier.isEmpty ? nil : identifier
    }

    private func itemRow(_ item: OfflineItemSettingsRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.itemType.sfSymbol)
                .foregroundStyle(item.itemType.tintColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lineLimit(1)
                    .help(item.title)
                if let identifier = Self.accountIdentifier(for: item.item) {
                    Text(identifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(identifier)
                        .accessibilityLabel("Username or email: \(identifier)")
                }
                if let lastRefreshedAt = item.lastRefreshedAt {
                    let timestamp = lastRefreshedAt.formatted(date: .abbreviated, time: .shortened)
                    let detail = String(localized: "\(item.itemType.displayName) · Last refreshed \(timestamp)")
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(detail)
                } else {
                    Text(item.itemType.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(statusLabel(for: item))
                .font(.caption)
                .foregroundStyle(statusColor(for: item))
                .accessibilityLabel(statusAccessibilityLabel(for: item))
            if coordinator.shouldOfferKeepOfflineIndividually(item.itemId) {
                Button("Keep offline individually") {
                    Task { await keepOfflineIndividually(item) }
                }
                .buttonStyle(.bordered)
                .disabled(!coordinator.canKeepOfflineIndividually(item.itemId))
            }
            if item.status == .failed || item.status == .notCached || item.status == .unavailable {
                Button("Retry") {
                    Task { await retryOfflineItem(item) }
                }
                .buttonStyle(.bordered)
                .disabled(!coordinator.canMakeNewSelections)
            }
            Button {
                Task { await removeOfflineItem(item) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove offline copy of \(item.title)")
            .accessibilityHint("Removes this item’s device-bound offline copy")
            .disabled(!coordinator.canRemoveItem(item.itemId))
        }
        .padding(.vertical, 4)
    }

    private func report(_ message: String, isError: Bool = false) {
        // Dismissing the sheet detaches feedback, never the service-owned operation.
        guard isVisible else { return }
        errorMessage = isError ? message : nil
        AccessibilityNotification.Announcement(message).post()
    }

    private func keepOfflineIndividually(_ item: OfflineItemSettingsRow) async {
        errorMessage = nil
        do {
            try await coordinator.keepOfflineIndividually(item.item)
            report(String(localized: "\(item.title) will remain available offline when its vault is turned off."))
        } catch {
            report(String(localized: "Could not keep this item offline. Retry offline status and try again."), isError: true)
        }
    }

    private func retryOfflineItem(_ item: OfflineItemSettingsRow) async {
        errorMessage = nil
        do {
            switch try await coordinator.retryOfflineItem(itemID: item.itemId, vaultID: item.vaultId) {
            case .submitted:
                report(String(localized: "Offline retry requested for \(item.title)."))
            case .unavailable:
                report(String(localized: "This item is no longer available for offline retry."), isError: true)
            }
        } catch {
            report(String(localized: "Could not retry this offline item. Retry offline status and try again."), isError: true)
        }
    }

    private func removeOfflineItem(_ item: OfflineItemSettingsRow) async {
        errorMessage = nil
        do {
            try await coordinator.removeOfflineItem(itemId: item.itemId)
            report(String(localized: "Offline copy removed for \(item.title)."))
        } catch {
            report(String(localized: "Could not remove offline copy. Try again."), isError: true)
        }
    }

    private func statusLabel(for item: OfflineItemSettingsRow) -> String {
        switch item.status {
        case .cached where item.hasUsableSnapshot: String(localized: "Cached")
        case .failed where item.hasUsableSnapshot: String(localized: "Stale")
        case .cached, .failed, .notCached, .unavailable: String(localized: "Unavailable")
        }
    }

    private func statusAccessibilityLabel(for item: OfflineItemSettingsRow) -> String {
        let timestamp = item.lastRefreshedAt.map { ", last refreshed \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
        return "\(statusLabel(for: item))\(timestamp)"
    }

    private func statusColor(for item: OfflineItemSettingsRow) -> Color {
        switch item.status {
        case .cached where item.hasUsableSnapshot: .green
        case .failed where item.hasUsableSnapshot: .orange
        case .cached, .failed, .notCached, .unavailable: .secondary
        }
    }
}
