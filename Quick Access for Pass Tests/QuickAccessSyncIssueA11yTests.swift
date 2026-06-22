import Testing
@testable import Quick_Access_for_Pass

@Suite("QuickAccessSyncIssueView accessibility")
@MainActor
struct QuickAccessSyncIssueA11yTests {
    @Test("skipped item inspect command accessibility label identifies item")
    func skippedItemInspectCommandAccessibilityLabelIdentifiesItem() {
        let label = QuickAccessSyncIssueView.inspectCommandAccessibilityLabel(for: makeSkippedItem())

        #expect(label == "Copy inspect command for item ID item-7 in vault Personal")
    }

    private func makeSkippedItem() -> SkippedSyncItem {
        SkippedSyncItem(
            vaultId: "vault",
            vaultName: "Personal",
            shareId: "share-7",
            itemIndex: 7,
            itemId: "item-7",
            codingPath: "items.Index 7.content",
            reason: "expected String"
        )
    }
}
