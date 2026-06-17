import Foundation

nonisolated struct QuickAccessViewContentInputs: Equatable, Sendable {
    let isLocked: Bool
    let hasDetailItem: Bool
    let hasItems: Bool
    let hasSyncError: Bool
    let hasSkippedItemDetails: Bool
    let hasErrorMessage: Bool
    let searchQuery: String
}

nonisolated enum QuickAccessViewContentState: Equatable, Sendable {
    case locked
    case syncError
    case itemContent
    case skippedItemDetails
    case errorMessage
    case noResults
    case shortcuts

    static func resolve(_ inputs: QuickAccessViewContentInputs) -> QuickAccessViewContentState {
        if inputs.isLocked { return .locked }
        if inputs.hasSyncError { return .syncError }
        if inputs.hasSkippedItemDetails { return .skippedItemDetails }
        if inputs.hasDetailItem || inputs.hasItems { return .itemContent }
        if inputs.hasErrorMessage { return .errorMessage }
        if !inputs.searchQuery.isEmpty { return .noResults }
        return .shortcuts
    }
}
