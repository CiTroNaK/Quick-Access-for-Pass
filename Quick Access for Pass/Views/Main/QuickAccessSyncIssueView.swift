import SwiftUI

nonisolated enum QuickAccessSyncIssueViewMode: Equatable, Sendable {
    case current
    case archived

    var contentPadding: CGFloat {
        switch self {
        case .current:
            20
        case .archived:
            0
        }
    }

    var minimumHeight: CGFloat? {
        switch self {
        case .current:
            260
        case .archived:
            nil
        }
    }

    var maximumHeight: CGFloat? {
        switch self {
        case .current:
            360
        case .archived:
            260
        }
    }

    func showsLoginAction(for presentation: QuickAccessSyncIssuePresentation) -> Bool {
        self == .current && presentation.showsLoginAction
    }

    func showsReportActions(for presentation: QuickAccessSyncIssuePresentation) -> Bool {
        presentation.showsReportActions
    }

    func showsDismissAction(for presentation: QuickAccessSyncIssuePresentation) -> Bool {
        self == .current && presentation.showsDismissAction
    }
}

struct QuickAccessSyncIssueView: View {
    let presentation: QuickAccessSyncIssuePresentation
    let mode: QuickAccessSyncIssueViewMode
    let performLogin: @MainActor @Sendable () -> Void
    let copyReport: @MainActor @Sendable () -> Void
    let copyAndReport: @MainActor @Sendable () -> Void
    let copySkippedItemCommand: @MainActor @Sendable (SkippedSyncItem) -> Void
    let dismiss: @MainActor @Sendable () -> Void

    init(
        presentation: QuickAccessSyncIssuePresentation,
        mode: QuickAccessSyncIssueViewMode = .current,
        performLogin: @escaping @MainActor @Sendable () -> Void,
        copyReport: @escaping @MainActor @Sendable () -> Void,
        copyAndReport: @escaping @MainActor @Sendable () -> Void,
        copySkippedItemCommand: @escaping @MainActor @Sendable (SkippedSyncItem) -> Void,
        dismiss: @escaping @MainActor @Sendable () -> Void
    ) {
        self.presentation = presentation
        self.mode = mode
        self.performLogin = performLogin
        self.copyReport = copyReport
        self.copyAndReport = copyAndReport
        self.copySkippedItemCommand = copySkippedItemCommand
        self.dismiss = dismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            preview
            actions
        }
        .padding(mode.contentPadding)
        .frame(
            maxWidth: .infinity,
            minHeight: mode.minimumHeight,
            maxHeight: mode.maximumHeight,
            alignment: .topLeading
        )
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

    static func inspectCommandAccessibilityLabel(for item: SkippedSyncItem) -> String {
        let itemLocator = if let itemId = item.itemId, !itemId.isEmpty {
            String(localized: "item ID \(itemId)", comment: "Skipped sync item ID in inspect command accessibility label.")
        } else {
            String(localized: "item index \(item.itemIndex)", comment: "Skipped sync item index in inspect command accessibility label.")
        }
        return String(
            localized: "Copy inspect command for \(itemLocator) in vault \(item.vaultName)",
            comment: "Accessibility label for copying a skipped sync item inspect command."
        )
    }

    private func skippedItemRow(_ item: SkippedSyncItem, summary: String) -> some View {
        let itemLocator = item.itemId.map {
            String(localized: "Item ID: \($0)", comment: "Skipped sync item ID.")
        } ?? String(localized: "Item index: \(item.itemIndex)", comment: "Skipped sync item index.")

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "Vault: \(item.vaultName)", comment: "Skipped sync item vault name."))
                        .font(.caption.weight(.semibold))
                    Text(itemLocator)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(String(localized: "Problem: \(item.codingPath)", comment: "Skipped sync item parse path."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Copy Inspect Command") {
                    copySkippedItemCommand(item)
                }
                .font(.caption2)
                .appClearGlassButtonStyle()
                .accessibilityLabel(Text(Self.inspectCommandAccessibilityLabel(for: item)))
            }
            Text(summary)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .lineLimit(3)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if mode.showsLoginAction(for: presentation) {
                Button("Log In") { performLogin() }
                    .appClearGlassButtonStyle()
            }
            if mode.showsReportActions(for: presentation) {
                Button("Copy Report") { copyReport() }
                    .appClearGlassButtonStyle()
                Button("Copy & Report") { copyAndReport() }
                    .appClearGlassButtonStyle()
                    .help(SyncErrorPresentation.copyAndReportHelpText)
            }
            Spacer()
            if mode.showsDismissAction(for: presentation) {
                Button("Dismiss") { dismiss() }
                    .appClearGlassButtonStyle()
            }
        }
        .font(.caption)
    }
}
