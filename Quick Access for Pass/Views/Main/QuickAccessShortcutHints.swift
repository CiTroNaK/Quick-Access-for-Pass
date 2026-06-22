import SwiftUI

struct QuickAccessShortcutHints: View {
    let hotkeyLabel: String
    let isLoading: Bool
    let hasItems: Bool
    let searchQuery: String
    let syncProgress: SyncProgressPresentation?
    let hasSkippedItems: Bool
    let syncIssueTrailingItem: QuickAccessFooterItem?
    let performSyncIssueAction: @MainActor @Sendable (QuickAccessFooterActionIntent) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let content = QuickAccessFooterContent.emptyStateContent(
                hotkeyLabel: hotkeyLabel,
                isSyncing: isLoading && !hasItems && searchQuery.isEmpty,
                syncProgress: syncProgress,
                hasSkippedItems: false,
                syncIssueTrailingItem: syncIssueTrailingItem,
                syncDescription: formatSyncTime(
                    UserDefaults.standard.double(forKey: "lastSyncTime"),
                    relativeTo: context.date
                )
            )

            QuickAccessFooter(
                leadingItems: content.leading,
                trailingItem: content.trailing,
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

    private func formatSyncTime(_ timestamp: Double, relativeTo now: Date) -> String? {
        guard timestamp > 0 else { return nil }
        return FormatHelpers.formatSyncTime(timestamp, relativeTo: now)
    }
}
