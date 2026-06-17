import SwiftUI

struct QuickAccessShortcutHints: View {
    let hotkeyLabel: String
    let isLoading: Bool
    let hasItems: Bool
    let searchQuery: String
    let syncProgress: SyncProgressPresentation?
    let hasSkippedItems: Bool
    let showSkippedItems: @MainActor @Sendable () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let content = QuickAccessFooterContent.emptyStateContent(
                hotkeyLabel: hotkeyLabel,
                isSyncing: isLoading && !hasItems && searchQuery.isEmpty,
                syncProgress: syncProgress,
                hasSkippedItems: hasSkippedItems,
                syncDescription: formatSyncTime(
                    UserDefaults.standard.double(forKey: "lastSyncTime"),
                    relativeTo: context.date
                )
            )

            QuickAccessFooter(
                leadingItems: content.leading,
                trailingItem: content.trailing,
                performAction: { intent in
                    if intent == .showSkippedItems {
                        showSkippedItems()
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
