import SwiftUI

struct QuickAccessShortcutHints: View {
    let hotkeyLabel: String
    let isLoading: Bool
    let hasItems: Bool
    let searchQuery: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let content = QuickAccessFooterContent.emptyStateContent(
                hotkeyLabel: hotkeyLabel,
                isSyncing: isLoading && !hasItems && searchQuery.isEmpty,
                syncDescription: formatSyncTime(
                    UserDefaults.standard.double(forKey: "lastSyncTime"),
                    relativeTo: context.date
                )
            )

            QuickAccessFooter(
                leadingItems: content.leading,
                trailingItem: content.trailing,
                performAction: { _ in }
            )
        }
    }

    private func formatSyncTime(_ timestamp: Double, relativeTo now: Date) -> String? {
        guard timestamp > 0 else { return nil }
        return FormatHelpers.formatSyncTime(timestamp, relativeTo: now)
    }
}
