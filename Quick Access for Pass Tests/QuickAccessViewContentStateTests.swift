import Testing
@testable import Quick_Access_for_Pass

@Suite("QuickAccessView content state")
struct QuickAccessViewContentStateTests {
    @Test("cached item content stays visible during sync errors")
    func cachedItemContentStaysVisibleDuringSyncErrors() {
        let state = QuickAccessViewContentState.resolve(QuickAccessViewContentInputs(
            isLocked: false,
            hasDetailItem: false,
            hasItems: true,
            hasSyncError: true,
            hasSkippedItemDetails: false,
            hasErrorMessage: false,
            searchQuery: "github"
        ))

        #expect(state == .itemContent)
    }

    @Test("shortcuts stay visible during skipped item diagnostics")
    func shortcutsStayVisibleDuringSkippedItemDiagnostics() {
        let state = QuickAccessViewContentState.resolve(QuickAccessViewContentInputs(
            isLocked: false,
            hasDetailItem: false,
            hasItems: false,
            hasSyncError: false,
            hasSkippedItemDetails: true,
            hasErrorMessage: false,
            searchQuery: ""
        ))

        #expect(state == .shortcuts)
    }

    @Test("normal empty state stays visible when sync fails with no cached items")
    func normalEmptyStateStaysVisibleWhenSyncFailsWithNoCachedItems() {
        let state = QuickAccessViewContentState.resolve(QuickAccessViewContentInputs(
            isLocked: false,
            hasDetailItem: false,
            hasItems: false,
            hasSyncError: true,
            hasSkippedItemDetails: false,
            hasErrorMessage: false,
            searchQuery: ""
        ))

        #expect(state == .shortcuts)
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

    @Test("no results state uses content with normal footer layout")
    func noResultsStateUsesContentWithNormalFooterLayout() {
        let state = QuickAccessViewContentState.resolve(QuickAccessViewContentInputs(
            isLocked: false,
            hasDetailItem: false,
            hasItems: false,
            hasSyncError: true,
            hasSkippedItemDetails: false,
            hasErrorMessage: false,
            searchQuery: "missing"
        ))

        #expect(state == .noResults)
        #expect(state.layout == .contentWithFooter)
    }

    @Test("shortcuts state remains footer only")
    func shortcutsStateRemainsFooterOnly() {
        let state = QuickAccessViewContentState.resolve(QuickAccessViewContentInputs(
            isLocked: false,
            hasDetailItem: false,
            hasItems: false,
            hasSyncError: false,
            hasSkippedItemDetails: false,
            hasErrorMessage: false,
            searchQuery: ""
        ))

        #expect(state == .shortcuts)
        #expect(state.layout == .footerOnly)
    }

    @Test("error message state remains content only")
    func errorMessageStateRemainsContentOnly() {
        let state = QuickAccessViewContentState.resolve(QuickAccessViewContentInputs(
            isLocked: false,
            hasDetailItem: false,
            hasItems: false,
            hasSyncError: false,
            hasSkippedItemDetails: false,
            hasErrorMessage: true,
            searchQuery: "missing"
        ))

        #expect(state == .errorMessage)
        #expect(state.layout == .contentOnly)
    }
}
