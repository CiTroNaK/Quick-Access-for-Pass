import SwiftUI

struct ItemDetailView: View {
    let item: PassItem
    var viewModel: QuickAccessViewModel
    let onBack: () -> Void
    let syncIssueTrailingItem: QuickAccessFooterItem?
    let performSyncIssueAction: @MainActor @Sendable (QuickAccessFooterActionIntent) -> Void

    init(
        item: PassItem,
        viewModel: QuickAccessViewModel,
        onBack: @escaping () -> Void,
        syncIssueTrailingItem: QuickAccessFooterItem? = nil,
        performSyncIssueAction: @escaping @MainActor @Sendable (QuickAccessFooterActionIntent) -> Void = { _ in }
    ) {
        self.item = item
        self.viewModel = viewModel
        self.onBack = onBack
        self.syncIssueTrailingItem = syncIssueTrailingItem
        self.performSyncIssueAction = performSyncIssueAction
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState var focusedRowID: DetailRow.ID?
    @State private var scrolledRowID: DetailRow.ID?

    var body: some View {
        VStack(spacing: 0) {
            itemHeader
            Divider().opacity(0.5)
            rowsList
            Spacer(minLength: 0)
            Divider().opacity(0.5)
            bottomBar
        }
    }

    // MARK: - Rows List

    private var rowsList: some View {
        let rows = viewModel.rows(for: item)
        return ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    rowView(row, indexInRows: index)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .scrollPosition(id: $scrolledRowID, anchor: .center)
        .onChange(of: viewModel.selectedDetailRowID) { _, _ in synchronizeSelection(in: rows) }
        .onChange(of: viewModel.detailRowSelectionEntries) { _, _ in synchronizeSelection(in: rows) }
        .onAppear { synchronizeSelection(in: rows) }
    }

    nonisolated static func selectionTarget(selectedID: DetailRow.ID?, rows: [DetailRow]) -> DetailRow.ID? {
        guard let selectedID, rows.contains(where: { $0.id == selectedID }) else { return nil }
        return selectedID
    }

    private func synchronizeSelection(in rows: [DetailRow]) {
        guard let selectedID = Self.selectionTarget(selectedID: viewModel.selectedDetailRowID, rows: rows) else {
            focusedRowID = nil
            scrolledRowID = nil
            return
        }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            scrolledRowID = selectedID
        }
        focusedRowID = selectedID
    }

    // MARK: - Item Header

    private var itemHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: item.itemType.sfSymbol)
                .font(.title2)
                .foregroundStyle(item.itemType.tintColor)
                .frame(width: 40, height: 40)
                .appGlassEffect(cornerRadius: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.body).fontWeight(.medium).lineLimit(1)
                Text(itemSubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Close", systemImage: "xmark", action: onBack)
                .labelStyle(.iconOnly)
                .font(.caption)
                .frame(width: 24, height: 24)
                .appClearGlassButtonStyle()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var itemSubtitle: String {
        var parts: [String] = []
        if !item.subtitle.isEmpty { parts.append(item.subtitle) }
        if let url = item.url { parts.append(url) }
        parts.append(QuickAccessFooterContent.detailVaultSubtitle(vaultName: viewModel.vaultName(for: item.vaultId)))
        return parts.joined(separator: " · ")
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        QuickAccessFooter(
            leadingItems: QuickAccessFooterContent.detailItems(),
            trailingItem: syncIssueTrailingItem,
            performAction: { intent in
                switch intent {
                case .login, .updatePAT, .showSyncIssues, .showSkippedItems:
                    performSyncIssueAction(intent)
                case .itemAction, .showDetail, .copyError, .dismissError:
                    return
                }
            }
        )
    }
}
