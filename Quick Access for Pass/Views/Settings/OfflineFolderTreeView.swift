import SwiftUI

/// Committed display rows and intent callbacks only: no discovery, database, or secret work in row bodies.
struct OfflineFolderTreeView: View {
    let rows: [OfflineFolderSettingsRow]
    let availability: FolderFeatureAvailability
    let vaultSelected: Bool
    let canSelect: (OfflineFolderSettingsRow) -> Bool
    let canDeselect: (OfflineFolderSettingsRow) -> Bool
    let onSelectionChange: (Bool, OfflineFolderSettingsRow) -> Void
    var matching = ""
    var selectedOnly = false
    /// Optional shared disclosure ownership lets the manager count the rows actually shown.
    var treeState: Binding<OfflineFolderTreeState>?
    /// Rows the owner already derived from the same inputs; avoids a second filter pass per render.
    var visibleRows: [OfflineFolderSettingsRow]?
    @Environment(\.locale) private var locale
    @State private var tree = OfflineFolderTreeState()

    var body: some View {
        let branches = OfflineFolderTreeState.branchIDs(rows)
        let paths = FolderSettingsLocalization.pathsByID(rows)
        let state = treeState?.wrappedValue ?? tree
        // Filtered views ignore collapse state, so disclosure controls would do nothing there.
        let isFiltering = selectedOnly || !matching.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(visibleRows ?? state.visibleRows(rows, availability: availability, matching: matching,
                                                     selectedOnly: selectedOnly, vaultSelected: vaultSelected)) { row in
                folderRow(row, showsDisclosure: branches.contains(row.id) && !isFiltering, paths: paths)
            }
        }
    }

    private func disclosureButton(for row: OfflineFolderSettingsRow, expanded: Bool) -> some View {
        Button {
            if let treeState { treeState.wrappedValue.toggleExpansion(row.id) } else { tree.toggleExpansion(row.id) }
        } label: {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .accessibilityHidden(true)
        }
        .buttonStyle(.borderless)
        .frame(width: 12)
        .accessibilityLabel(expanded
            ? FolderSettingsLocalization.text("Collapse folder \(row.path)", locale: locale)
            : FolderSettingsLocalization.text("Expand folder \(row.path)", locale: locale))
        .accessibilityValue(expanded
            ? FolderSettingsLocalization.text("Expanded", locale: locale)
            : FolderSettingsLocalization.text("Collapsed", locale: locale))
    }

    private func folderRow(_ row: OfflineFolderSettingsRow, showsDisclosure: Bool,
                           paths: [OfflineFolderSettingsRow.ID: String]) -> some View {
        let inherited = OfflineFolderTreeState.isInheritedOnly(row, vaultSelected: vaultSelected)
        let included = row.isSelected || inherited
        let expanded = !(treeState?.wrappedValue ?? tree).collapsed.contains(row.id)
        let description = FolderSettingsLocalization.policyDescription(row, pathsByID: paths,
                                                                        vaultSelected: vaultSelected, locale: locale)
        return HStack(alignment: .top, spacing: 8) {
            if availability == .supported && showsDisclosure {
                disclosureButton(for: row, expanded: expanded)
            } else {
                Color.clear.frame(width: 12, height: 12).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle(isOn: Binding(get: { included }, set: { selected in
                    // Inherited checkmarks are not a hidden child-policy writer or ancestor off-switch.
                    guard !inherited else { return }
                    onSelectionChange(selected, row)
                })) {
                    HStack(spacing: 5) {
                        Image(systemName: "folder").accessibilityHidden(true)
                        Text(verbatim: availability == .supported ? row.folderName : row.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(inherited || (row.isSelected ? !canDeselect(row) : !canSelect(row)))
                .accessibilityLabel(Text(verbatim: row.path))
                .accessibilityValue(description)
                .accessibilityHint(FolderSettingsLocalization.text("Includes subfolders and future items after a complete sync.", locale: locale))
                .accessibilityAddTraits(included ? .isSelected : [])
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(description)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(FolderSettingsLocalization.counts(selected: row.selectedCount, usable: row.usableCount, locale: locale))
                    .font(.caption)
                if let refreshed = row.lastRefreshedAt {
                    Text(refreshed, format: Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale))
                        .font(.caption2)
                }
            }
            .foregroundStyle(.secondary)
        }
        // Deep paths retain their full help/accessibility value without consuming the entire pane width.
        .padding(.leading, availability == .supported ? CGFloat(min(row.depth, 8) * 12) : 0)
        .help(row.path)
        .accessibilityElement(children: .contain)
    }
}
