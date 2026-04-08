import SwiftUI

struct ItemDetailView: View {
    let item: PassItem
    var viewModel: QuickAccessViewModel
    let onBack: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var focusedRowID: DetailRow.ID?
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

    // MARK: - Row Trailing Content

    /// Describes what appears at the trailing edge of a selectable row and
    /// what accessibility hint the row announces. Deriving both from a
    /// single source stops the two from drifting: the trailing text and
    /// the VoiceOver hint are always consistent because they flow from the
    /// same case.
    ///
    /// `internal` (not `private`) so it is visible to the test target via
    /// `@testable import`.
    nonisolated enum RowTrailing: Equatable {
        /// Top-group shortcut label (⌘C, ⌘U, ⌘P, ⌘T) with no explicit hint.
        case shortcut(String)
        /// Open-in-browser row: render the ⌘O shortcut AND announce
        /// "Press Return to open" under VoiceOver.
        case openShortcut(String)
        /// Bottom-group field row: render the ⏎ + Copy glyph pair and
        /// announce "Press Return to copy".
        case copyHint
    }

    /// Pure mapping from `DetailRow` to `RowTrailing`. Returns `nil` for
    /// non-selectable rows (section headers) which render their own view
    /// and never reach `selectableRow`.
    ///
    /// `internal` + `static` so it can be unit-tested without instantiating
    /// a SwiftUI host.
    nonisolated static func rowTrailing(for row: DetailRow) -> RowTrailing? {
        switch row {
        case .namedAction(let action, _, let shortcut):
            return action == .openURL ? .openShortcut(shortcut) : .shortcut(shortcut)
        case .field:
            return .copyHint
        case .sectionHeader:
            return nil
        }
    }

    private struct SelectableRowProps {
        let rowID: DetailRow.ID
        let indexInRows: Int
        let icon: String
        let label: String
        let trailing: RowTrailing
        let isSensitive: Bool
        let action: @Sendable @MainActor () -> Void
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
        .onChange(of: viewModel.selectedRowIndex) { _, newValue in
            guard rows.indices.contains(newValue) else { return }
            let targetID = rows[newValue].id
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                scrolledRowID = targetID
            }
            focusedRowID = targetID
        }
        .onAppear {
            guard rows.indices.contains(viewModel.selectedRowIndex) else { return }
            focusedRowID = rows[viewModel.selectedRowIndex].id
        }
    }

    @ViewBuilder
    private func rowView(_ row: DetailRow, indexInRows: Int) -> some View {
        switch row {
        case .namedAction(let action, let label, _):
            if let trailing = Self.rowTrailing(for: row) {
                selectableRow(
                    props: SelectableRowProps(
                        rowID: row.id,
                        indexInRows: indexInRows,
                        icon: action.sfSymbol,
                        label: label,
                        trailing: trailing,
                        isSensitive: false,
                        action: { viewModel.handleAction(action, for: item) }
                    )
                )
            }
        case .field(let key, let label, let isSensitive):
            if let trailing = Self.rowTrailing(for: row) {
                selectableRow(
                    props: SelectableRowProps(
                        rowID: row.id,
                        indexInRows: indexInRows,
                        icon: isSensitive ? "lock.fill" : "doc.plaintext",
                        label: label,
                        trailing: trailing,
                        isSensitive: isSensitive,
                        action: { viewModel.copyField(key, from: item) }
                    )
                )
            }
        case .sectionHeader(let name, _):
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private func selectableRow(props: SelectableRowProps) -> some View {
        let isSelected = viewModel.selectedRowIndex == props.indexInRows
        let hint: String = {
            switch props.trailing {
            case .copyHint: return String(localized: "Press Return to copy")
            case .openShortcut: return String(localized: "Press Return to open")
            case .shortcut: return ""
            }
        }()
        Button {
            viewModel.selectedRowIndex = props.indexInRows
            props.action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: props.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(props.label)
                    .font(.body)
                Spacer()
                if viewModel.isActionLoading && isSelected {
                    ProgressView().controlSize(.small)
                } else {
                    trailingView(props.trailing, isSelected: isSelected)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.tint.opacity(0.15))
                        .appGlassEffect(cornerRadius: 8)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isActionLoading)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityFocused($focusedRowID, equals: props.rowID)
        .modifier(ConditionalAccessibilityValue(isSensitive: props.isSensitive))
        .modifier(ConditionalAccessibilityHint(hint: hint))
    }

    @ViewBuilder
    private func trailingView(_ trailing: RowTrailing, isSelected: Bool) -> some View {
        switch trailing {
        case .shortcut(let text) where !text.isEmpty:
            Text(text)
                .font(.caption)
                .foregroundStyle(isSelected ? .secondary : .tertiary)
                .accessibilityHidden(true)
        case .openShortcut(let text) where !text.isEmpty:
            Text(text)
                .font(.caption)
                .foregroundStyle(isSelected ? .secondary : .tertiary)
                .accessibilityHidden(true)
        case .shortcut, .openShortcut:
            EmptyView()
        case .copyHint:
            // Use Text(verbatim:) for the glyph and a separate Text("Copy")
            // for the word so the existing "Copy" localization entry is
            // reused instead of forcing the user to add "⏎ Copy" as a new
            // xcstrings key. The user maintains Localizable.xcstrings
            // manually, so introducing new glyph-prefixed keys is a cost.
            (Text(verbatim: "⏎ ") + Text("Copy"))
                .font(.caption)
                .foregroundStyle(isSelected ? .secondary : .tertiary)
                .opacity(isSelected ? 1 : 0.35)
                .accessibilityHidden(true)
        }
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
            trailingItem: nil,
            performAction: { _ in }
        )
    }
}

private struct ConditionalAccessibilityValue: ViewModifier {
    let isSensitive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isSensitive {
            content.accessibilityValue(String(localized: "hidden field"))
        } else {
            content
        }
    }
}

private struct ConditionalAccessibilityHint: ViewModifier {
    let hint: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if hint.isEmpty {
            content
        } else {
            content.accessibilityHint(hint)
        }
    }
}
