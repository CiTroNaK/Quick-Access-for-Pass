import SwiftUI

extension QuickAccessView {
    @ViewBuilder
    var content: some View {
        if let syncError = viewModel.syncError {
            QuickAccessSyncErrorView(presentation: syncError) { action in
                viewModel.handleSyncErrorAction(action)
            }
        } else if viewModel.isShowingSkippedSyncItems, let skippedItems = viewModel.skippedSyncItems {
            QuickAccessSkippedItemsView(
                presentation: skippedItems,
                copyReport: { viewModel.copySkippedSyncItemsReport() },
                copyAndReport: { viewModel.copyAndReportSkippedSyncItems() },
                dismiss: { viewModel.hideSkippedSyncItems() }
            )
        } else if let detailItem = viewModel.detailItem {
            VStack(spacing: 0) {
                ItemDetailView(
                    item: detailItem,
                    viewModel: viewModel,
                    onBack: { viewModel.hideDetail() }
                )
                .frame(maxHeight: .infinity)

                if let error = viewModel.errorMessage {
                    Divider()
                        .opacity(0.5)
                    detailErrorBar(error)
                }
            }
        } else if !viewModel.items.isEmpty {
            VStack(spacing: 0) {
                QuickAccessResultsList(
                    items: viewModel.items,
                    selectedIndex: viewModel.selectedIndex,
                    vaultName: viewModel.vaultName(for:),
                    showDetailAtIndex: { index in
                        viewModel.selectedIndex = index
                        viewModel.showDetail()
                    }
                )
                Divider()
                    .opacity(0.5)
                QuickAccessActionBar(viewModel: viewModel)
            }
        } else if let error = viewModel.errorMessage {
            QuickAccessEmptyStateView(message: error, secondaryMessage: nil, systemImage: nil)
        } else if !viewModel.searchQuery.isEmpty {
            QuickAccessEmptyStateView(
                message: "No items found",
                secondaryMessage: "Try a different search or press ⌘R to refresh",
                systemImage: "magnifyingglass"
            )
        }
    }

    func detailErrorBar(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
            Spacer()
            Button("Dismiss") { viewModel.errorMessage = nil }
                .font(.caption)
                .appClearGlassButtonStyle()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
