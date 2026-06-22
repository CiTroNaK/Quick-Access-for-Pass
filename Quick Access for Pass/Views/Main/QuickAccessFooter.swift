import SwiftUI

struct QuickAccessFooter: View {
    let leadingItems: [QuickAccessFooterItem]
    let trailingItem: QuickAccessFooterItem?
    let performAction: @MainActor @Sendable (QuickAccessFooterActionIntent) -> Void

    nonisolated static let prominentActionHeight: CGFloat = 24
    nonisolated static let prominentActionHorizontalPadding: CGFloat = 10

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
        case .action(let intent, let title, let shortcut):
            actionItemView(
                intent: intent,
                title: title,
                shortcut: shortcut,
                presentation: item.footerActionPresentation
            )

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

    private func actionItemView(
        intent: QuickAccessFooterActionIntent,
        title: String,
        shortcut: String?,
        presentation: QuickAccessFooterActionPresentation
    ) -> some View {
        let isProminent = presentation.isProminent

        return Button {
            performAction(intent)
        } label: {
            HStack(spacing: 6) {
                if let symbolName = presentation.symbolName {
                    Image(systemName: symbolName)
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
                Text(title)
                if let shortcut, !shortcut.isEmpty {
                    shortcutPill(shortcut, foreground: .tertiary)
                }
            }
            .padding(.horizontal, isProminent ? Self.prominentActionHorizontalPadding : 0)
            .frame(height: isProminent ? Self.prominentActionHeight : nil)
        }
        .buttonStyle(.plain)
        .font(isProminent ? .caption.weight(.semibold) : .caption)
        .foregroundStyle(foregroundStyle(for: presentation))
        .background {
            if isProminent {
                Capsule(style: .continuous)
                    .fill(backgroundColor(for: presentation))
            }
        }
        .overlay {
            if isProminent {
                Capsule(style: .continuous)
                    .stroke(strokeColor(for: presentation), lineWidth: 1)
            }
        }
        .lineLimit(1)
        .layoutPriority(isProminent ? 1 : 0)
    }

    private func foregroundStyle(for presentation: QuickAccessFooterActionPresentation) -> AnyShapeStyle {
        switch presentation.tone {
        case .secondary:
            AnyShapeStyle(presentation.isProminent ? Color.primary : Color.secondary)
        case .warning:
            AnyShapeStyle(Color.orange)
        case .error:
            AnyShapeStyle(Color.red)
        }
    }

    private func backgroundColor(for presentation: QuickAccessFooterActionPresentation) -> Color {
        switch presentation.tone {
        case .secondary:
            Color.primary.opacity(0.10)
        case .warning:
            Color.orange.opacity(0.16)
        case .error:
            Color.red.opacity(0.14)
        }
    }

    private func strokeColor(for presentation: QuickAccessFooterActionPresentation) -> Color {
        switch presentation.tone {
        case .secondary:
            Color.primary.opacity(0.18)
        case .warning:
            Color.orange.opacity(0.55)
        case .error:
            Color.red.opacity(0.50)
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
