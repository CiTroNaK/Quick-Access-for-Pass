import SwiftUI

struct QuickAccessSkippedItemsView: View {
    let presentation: SyncSkippedItemsPresentation
    let copyReport: @MainActor @Sendable () -> Void
    let copyAndReport: @MainActor @Sendable () -> Void
    let dismiss: @MainActor @Sendable () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(presentation.visibleItems.enumerated()), id: \.offset) { index, item in
                        skippedItemRow(item, summary: presentation.visibleSummaries[index])
                    }
                    if presentation.hiddenItemCount > 0 {
                        Text("+\(presentation.hiddenItemCount) more in copied report")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            actions
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 260, maxHeight: 360, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Skipped Sync Items")
                .font(.headline)
            Text("These items could not be parsed, but the rest of your vault synced successfully.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func skippedItemRow(_ item: SkippedSyncItem, summary: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.vaultName)
                .font(.caption.weight(.semibold))
            Text(summary)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Copy Report") { copyReport() }
                .appClearGlassButtonStyle()
            Button("Copy & Report") { copyAndReport() }
                .appClearGlassButtonStyle()
            Spacer()
            Button("Dismiss") { dismiss() }
                .appClearGlassButtonStyle()
        }
        .font(.caption)
    }
}
