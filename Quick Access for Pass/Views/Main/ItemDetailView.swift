import SwiftUI

struct ItemDetailView: View {
    let item: PassItem
    var viewModel: QuickAccessViewModel
    let onBack: () -> Void
    let syncIssueTrailingItem: QuickAccessFooterItem?
    let performSyncIssueAction: @MainActor @Sendable (QuickAccessFooterActionIntent) -> Void

    init(
        item: PassItem,
        viewModel: QuickAccessViewModel,
        onBack: @escaping () -> Void,
        syncIssueTrailingItem: QuickAccessFooterItem? = nil,
        performSyncIssueAction: @escaping @MainActor @Sendable (QuickAccessFooterActionIntent) -> Void = { _ in }
    ) {
        self.item = item
        self.viewModel = viewModel
        self.onBack = onBack
        self.syncIssueTrailingItem = syncIssueTrailingItem
        self.performSyncIssueAction = performSyncIssueAction
    }

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
        /// Offline availability rows are visible actions without a shortcut.
        case offlineAction
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
        case .offlineAvailability, .keepOfflineIndividually:
            return .offlineAction
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
        let isEnabled: Bool
        let statusText: String?
        let accessibilityHint: String
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
        .onChange(of: viewModel.selectedDetailRowID) { _, _ in synchronizeSelection(in: rows) }
        .onChange(of: viewModel.detailRowSelectionEntries) { _, _ in synchronizeSelection(in: rows) }
        .onAppear { synchronizeSelection(in: rows) }
    }

    nonisolated static func selectionTarget(selectedID: DetailRow.ID?, rows: [DetailRow]) -> DetailRow.ID? {
        guard let selectedID, rows.contains(where: { $0.id == selectedID }) else { return nil }
        return selectedID
    }

    private func synchronizeSelection(in rows: [DetailRow]) {
        guard let selectedID = Self.selectionTarget(selectedID: viewModel.selectedDetailRowID, rows: rows) else {
            focusedRowID = nil
            scrolledRowID = nil
            return
        }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            scrolledRowID = selectedID
        }
        focusedRowID = selectedID
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
                        isEnabled: true,
                        statusText: nil,
                        accessibilityHint: "",
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
                        isEnabled: true,
                        statusText: nil,
                        accessibilityHint: "",
                        action: { viewModel.copyField(key, from: item) }
                    )
                )
            }
        case .offlineAvailability(let availability):
            if let trailing = Self.rowTrailing(for: row) {
                selectableRow(
                    props: SelectableRowProps(
                        rowID: row.id,
                        indexInRows: indexInRows,
                        icon: Self.offlineIcon(for: availability),
                        label: Self.offlineLabel(for: availability),
                        trailing: trailing,
                        isSensitive: false,
                        isEnabled: viewModel.offlineModeCoordinator?.isOperating(on: item) != true,
                        statusText: Self.offlineStatusText(for: availability),
                        accessibilityHint: "",
                        action: { viewModel.handleOfflineAvailability(for: item) }
                    )
                )
            }
        case .keepOfflineIndividually:
            selectableRow(
                props: SelectableRowProps(
                    rowID: row.id,
                    indexInRows: indexInRows,
                    icon: "pin",
                    label: Self.keepOfflineLabel,
                    trailing: .offlineAction,
                    isSensitive: false,
                    isEnabled: viewModel.offlineModeCoordinator?.canKeepOfflineIndividually(item.id) == true,
                    statusText: nil,
                    accessibilityHint: "",
                    action: { viewModel.handleKeepOfflineIndividually(for: item) }
                )
            )
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

    nonisolated static let keepOfflineLabel = String(localized: "Keep offline individually")

    /// `internal` + `static` so offline action presentation can be unit-tested.
    nonisolated static func offlineLabel(for availability: OfflineItemAvailability) -> String {
        switch availability {
        case .available, .stale:
            String(localized: "Remove offline copy")
        case .notCached, .unavailable:
            String(localized: "Make available offline")
        }
    }

    /// `internal` + `static` so offline action presentation can be unit-tested.
    nonisolated static func offlineStatusText(for availability: OfflineItemAvailability) -> String? {
        switch availability {
        case .available: String(localized: "Cached")
        case .stale: String(localized: "Stale")
        case .unavailable: String(localized: "Unavailable")
        case .notCached: nil
        }
    }

    nonisolated static func offlineIcon(for availability: OfflineItemAvailability) -> String {
        switch availability {
        case .available, .stale:
            "trash"
        case .notCached, .unavailable:
            "arrow.down.circle"
        }
    }

    @ViewBuilder
    private func selectableRow(props: SelectableRowProps) -> some View {
        let isSelected = viewModel.selectedDetailRowID == props.rowID
        let hint: String = {
            switch props.trailing {
            case .copyHint: return String(localized: "Press Return to copy")
            case .openShortcut: return String(localized: "Press Return to open")
            case .shortcut, .offlineAction: return ""
            }
        }()
        let accessibilityHint = props.accessibilityHint.isEmpty ? hint : props.accessibilityHint
        Button {
            viewModel.selectDetailRow(id: props.rowID)
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
                if let statusText = props.statusText {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if viewModel.isOfflineOperation && props.trailing == .offlineAction {
                    ProgressView().controlSize(.small)
                } else if viewModel.isActionLoading && isSelected {
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
        .disabled(!props.isEnabled || (viewModel.isActionLoading && (!viewModel.isOfflineOperation || isSelected)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityFocused($focusedRowID, equals: props.rowID)
        .modifier(ConditionalAccessibilityValue(isSensitive: props.isSensitive))
        .modifier(ConditionalAccessibilityHint(hint: accessibilityHint))
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
        case .offlineAction:
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
            trailingItem: syncIssueTrailingItem,
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
