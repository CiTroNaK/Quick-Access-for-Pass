import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Local offline folder picker projection")
struct OfflineFolderPickerStateTests {
    @Test func filterFindsLiteralPathsAndRetainsAncestorContext() {
        let rows = hierarchy()
        let tree = OfflineFolderTreeState()
        #expect(tree.visibleRows(rows, availability: .supported, matching: "networking").map(\.folderID)
            == ["root", "infra", "network", "router"])
        #expect(tree.visibleRows(rows, availability: .supported, matching: "ÚČTY").map(\.folderID) == ["literal"])
        #expect(tree.visibleRows(rows, availability: .supported, matching: "%{not-a-key}").map(\.folderID) == ["literal"])
        #expect(tree.visibleRows(rows, availability: .supported, matching: "\n  ") == rows)
        #expect(tree.visibleRows(rows, availability: .supported, matching: "absent").isEmpty)
    }

    @Test func activeFiltersRevealMatchesWithoutChangingCollapsedState() {
        let rows = hierarchy()
        var tree = OfflineFolderTreeState()
        tree.toggleExpansion(rows[0].id)
        let saved = tree.collapsed
        #expect(tree.visibleRows(rows, availability: .supported).map(\.folderID) == ["root", "empty", "literal", "root"])
        #expect(tree.visibleRows(rows, availability: .supported, matching: "Networking").map(\.folderID)
            == ["root", "infra", "network", "router"])
        #expect(tree.visibleRows(rows, availability: .supported, selectedOnly: true).map(\.folderID)
            == ["root", "infra", "network", "router", "empty"])
        #expect(tree.collapsed == saved)
        #expect(tree.visibleRows(rows, availability: .supported, matching: "").map(\.folderID)
            == ["root", "empty", "literal", "root"])
    }

    @Test func selectedOnlyIncludesCoverageWithoutManufacturingIntent() {
        let rows = hierarchy()
        let visible = OfflineFolderTreeState().visibleRows(rows, availability: .supported, selectedOnly: true)
        #expect(visible.map(\.folderID) == ["root", "infra", "network", "router", "empty"])
        #expect(visible.filter(\.isSelected).map(\.folderID) == ["infra", "empty"])
        #expect(visible.first?.isSelected == false)
        #expect(visible[2].coveringAncestorID == "infra")
        #expect(OfflineFolderTreeState().visibleRows(rows, availability: .supported, selectedOnly: true, vaultSelected: true) == rows)
        #expect(OfflineFolderTreeState().visibleRows(rows, availability: .supported, matching: "networking", selectedOnly: true)
            .map(\.folderID) == ["root", "infra", "network", "router"])
    }

    @Test func literalSeparatorsAndDuplicateIDsDoNotInventAncestry() {
        let rows = [row("same", names: ["A / B"]), row("child", names: ["A / B", "Leaf"]),
                    row("same", vault: "other", names: ["Different"]),
                    row("child", vault: "other", names: ["Different", "Leaf"], selected: true)]
        let tree = OfflineFolderTreeState()
        let visible = tree.visibleRows(rows, availability: .supported, matching: "different / leaf")
        #expect(visible.map(\.id) == [.init(vaultID: "other", folderID: "same"), .init(vaultID: "other", folderID: "child")])
        #expect(tree.visibleRows(rows, availability: .supported, matching: "A / B / Leaf").map(\.vaultID) == ["vault", "vault"])
        #expect(tree.visibleRows(rows, availability: .supported, selectedOnly: true).map(\.vaultID) == ["other", "other"])
    }

    @Test(arguments: [FolderFeatureAvailability.requiresUpgrade, .checking, .unavailable])
    func unsupportedProjectionAlwaysExposesExplicitRemovalRows(availability: FolderFeatureAvailability) {
        let rows = hierarchy()
        var tree = OfflineFolderTreeState()
        tree.toggleExpansion(rows[0].id)
        #expect(tree.visibleRows(rows, availability: availability, matching: "no-match", selectedOnly: true, vaultSelected: true)
            .map(\.folderID) == ["infra", "empty"])
    }

    @Test(arguments: [0, 1, 40, 1300])
    func filteringIsPureAndStableAtScale(count: Int) {
        let rows = (0..<count).map { row("id-\($0)", names: ["Folder \($0)"], selected: $0.isMultiple(of: 2)) }
        let tree = OfflineFolderTreeState()
        let filtered = tree.visibleRows(rows, availability: .supported, selectedOnly: true)
        #expect(filtered.map(\.folderID) == stride(from: 0, to: count, by: 2).map { "id-\($0)" })
        #expect(Set(filtered.map(\.id)).count == filtered.count)
        #expect(filtered.allSatisfy { rows.contains($0) })
        #expect(tree.collapsed.isEmpty)
        #expect(tree.visibleRows(rows, availability: .supported) == rows)
    }

    private func hierarchy() -> [OfflineFolderSettingsRow] {
        [row("root", names: ["Development"]),
         row("infra", names: ["Development", "Infrastructure"], selected: true),
         row("network", names: ["Development", "Infrastructure", "Networking"], ancestor: "infra"),
         row("router", names: ["Development", "Infrastructure", "Networking", "Router"], ancestor: "infra"),
         row("apps", names: ["Development", "Applications"]),
         row("empty", names: ["Empty"], selected: true),
         row("literal", names: ["Osobní / %{not-a-key} — účty"]),
         row("root", vault: "other", names: ["Different"])]
    }

    private func row(_ id: String, vault: String = "vault", names: [String], selected: Bool = false,
                     ancestor: String? = nil) -> OfflineFolderSettingsRow {
        .init(vaultID: vault, folderID: id, folderName: names.last ?? "", location: .init(folderID: id, ancestorNames: names),
              isSelected: selected, coveringAncestorID: ancestor, selectedCount: 2, usableCount: 1,
              lastRefreshedAt: Date(timeIntervalSince1970: 100))
    }
}
