import AppKit
import GRDB
import SwiftUI
import Testing
@testable import Quick_Access_for_Pass

@Suite("Synthetic offline folder tree rendering", .timeLimit(.minutes(1)))
@MainActor
struct OfflineFolderTreeRenderingTests {
    @Test(arguments: ["en", "cs"])
    func longInheritedPathsStayBoundedWithoutInvokingActions(language: String) {
        var actionCount = 0
        func height(_ name: String) -> CGFloat {
            let parent = row("parent", names: [name], selected: true)
            let child = row("child", names: [name, "Child"], selected: false, ancestor: "parent")
            let host = NSHostingView(rootView: OfflineFolderTreeView(rows: [parent, child], availability: .supported,
                vaultSelected: false, canSelect: { _ in true }, canDeselect: { _ in true },
                onSelectionChange: { _, _ in actionCount += 1 })
                .environment(\.locale, Locale(identifier: language)).frame(width: 600))
            return host.fittingSize.height
        }
        let ordinary = height("Parent")
        let long = height(String(repeating: "Osobní / %{not-a-key} — účty ", count: 100))
        #expect(ordinary > 0)
        #expect(long <= ordinary + 32)
        #expect(actionCount == 0)
    }

    @Test func folderContextDoesNotExpandItemManagerMatching() async throws {
        let f = try await OfflineFolderFixture.make()
        let selection = try #require(try await f.select("parent"))
        try await f.cache(selection)
        let presentation = try await f.database.reader.read { try OfflineCatalogObservation.presentation(in: $0) }
        #expect(presentation.folderLocationsByItemID["item"]?.path == "Parent / Child")
        #expect(!presentation.itemGroups.isEmpty)
        #expect(OfflineItemsManagerView.filteredGroups(presentation.itemGroups, matching: "Parent").isEmpty)
        #expect(OfflineItemsManagerView.filteredGroups(presentation.itemGroups, matching: "Child").isEmpty)
        #expect(!OfflineItemsManagerView.filteredGroups(presentation.itemGroups, matching: "Offline example").isEmpty)
    }

    private func row(_ id: String, names: [String], selected: Bool, ancestor: String? = nil) -> OfflineFolderSettingsRow {
        .init(vaultID: "vault", folderID: id, folderName: names.last ?? "", location: .init(folderID: id, ancestorNames: names),
            isSelected: selected, coveringAncestorID: ancestor, selectedCount: 0, usableCount: 0, lastRefreshedAt: nil)
    }
}
