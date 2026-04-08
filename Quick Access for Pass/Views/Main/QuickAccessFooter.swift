import SwiftUI

struct QuickAccessFooter: View {
    let leadingItems: [QuickAccessFooterItem]
    let trailingItem: QuickAccessFooterItem?
    let performAction: @MainActor @Sendable (QuickAccessFooterActionIntent) -> Void

    private var compactLeadingItems: [QuickAccessFooterItem] {
        let preserved = leadingItems.filter { !$0.collapsesWhenTight }
        return preserved.isEmpty ? Array(leadingItems.prefix(1)) : preserved
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            footerRow(leadingItems, trailingItem: trailingItem)
            footerRow(compactLeadingItems, trailingItem: trailingItem)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func footerRow(_ items: [QuickAccessFooterItem], trailingItem: QuickAccessFooterItem?) -> some View {
        HStack(spacing: 12) {
            ForEach(items) { item in
                itemView(item)
            }
            Spacer(minLength: 0)
            if let trailingItem {
                itemView(trailingItem)
            }
        }
    }

    @ViewBuilder
    private func itemView(_ item: QuickAccessFooterItem) -> some View {
        switch item {
        case .action(_, let title, let shortcut):
            HStack(spacing: 6) {
                Text(title)
                if let shortcut, !shortcut.isEmpty {
                    shortcutPill(shortcut, foreground: .tertiary)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .layoutPriority(0)

        case .hint(let title, let shortcut, _):
            HStack(spacing: 6) {
                if let shortcut, !shortcut.isEmpty {
                    shortcutPill(shortcut, foreground: .tertiary)
                }
                Text(title)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .layoutPriority(0)

        case .status(let text, let symbol, let tone, let showsProgress, _):
            HStack(spacing: 6) {
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(text)
                } else if let symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(tone == .error ? .red : .secondary)
                        .accessibilityHidden(true)
                }
                Text(text)
                    .font(.caption)
                    .foregroundStyle(tone == .error ? .red : .secondary)
                    .lineLimit(1)
            }
            .layoutPriority(0)
        }
    }

    private func shortcutPill(_ shortcut: String, foreground: HierarchicalShapeStyle) -> some View {
        Text(shortcut)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                Capsule(style: .continuous)
                    .fill(.white.opacity(0.08))
            }
    }
}
