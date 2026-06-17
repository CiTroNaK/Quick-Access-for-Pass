import SwiftUI

struct QuickAccessSyncIssueView: View {
    let presentation: QuickAccessSyncIssuePresentation
    let performLogin: @MainActor @Sendable () -> Void
    let copyReport: @MainActor @Sendable () -> Void
    let copyAndReport: @MainActor @Sendable () -> Void
    let dismiss: @MainActor @Sendable () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            preview
            actions
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 260, maxHeight: 360, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(presentation.title)
                .font(.headline)
            Text(presentation.message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch presentation.preview {
        case .none:
            Spacer(minLength: 0)
        case .diagnostic(let diagnostic):
            ScrollView {
                Text(diagnostic)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .skippedItems(let skippedItems):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(skippedItems.visibleItems.enumerated()), id: \.offset) { index, item in
                        skippedItemRow(item, summary: skippedItems.visibleSummaries[index])
                    }
                    if skippedItems.hiddenItemCount > 0 {
                        Text("+\(skippedItems.hiddenItemCount) more in copied report")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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
            if presentation.showsLoginAction {
                Button("Log In") { performLogin() }
                    .appClearGlassButtonStyle()
            }
            if presentation.showsReportActions {
                Button("Copy Report") { copyReport() }
                    .appClearGlassButtonStyle()
                Button("Copy & Report") { copyAndReport() }
                    .appClearGlassButtonStyle()
                    .help(SyncErrorPresentation.copyAndReportHelpText)
            }
            Spacer()
            if presentation.showsDismissAction {
                Button("Dismiss") { dismiss() }
                    .appClearGlassButtonStyle()
            }
        }
        .font(.caption)
    }
}
