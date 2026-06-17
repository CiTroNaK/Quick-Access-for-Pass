import Testing
@testable import Quick_Access_for_Pass

@Suite("QuickAccessView content state")
struct QuickAccessViewContentStateTests {
    @Test("sync error takes precedence over cached item content")
    func syncErrorTakesPrecedenceOverCachedItemContent() {
        let state = QuickAccessViewContentState.resolve(QuickAccessViewContentInputs(
            isLocked: false,
            hasDetailItem: false,
            hasItems: true,
            hasSyncError: true,
            hasSkippedItemDetails: false,
            hasErrorMessage: false,
            searchQuery: "github"
        ))

        #expect(state == .syncError)
    }

    @Test("skipped item details take precedence over shortcuts")
    func skippedItemDetailsTakePrecedenceOverShortcuts() {
        let state = QuickAccessViewContentState.resolve(QuickAccessViewContentInputs(
            isLocked: false,
            hasDetailItem: false,
            hasItems: false,
            hasSyncError: false,
            hasSkippedItemDetails: true,
            hasErrorMessage: false,
            searchQuery: ""
        ))

        #expect(state == .skippedItemDetails)
    }

    @Test("successful login clears sync error back to item content")
    func itemContentReturnsAfterSyncErrorClears() {
        let state = QuickAccessViewContentState.resolve(QuickAccessViewContentInputs(
            isLocked: false,
            hasDetailItem: false,
            hasItems: true,
            hasSyncError: false,
            hasSkippedItemDetails: false,
            hasErrorMessage: false,
            searchQuery: "github"
        ))

        #expect(state == .itemContent)
    }
}
