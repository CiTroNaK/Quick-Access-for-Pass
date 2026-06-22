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

nonisolated enum QuickAccessViewContentLayout: Equatable, Sendable {
    case contentOnly
    case footerOnly
    case contentWithFooter
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
        if inputs.hasDetailItem || inputs.hasItems { return .itemContent }
        if inputs.hasErrorMessage { return .errorMessage }
        if !inputs.searchQuery.isEmpty { return .noResults }
        return .shortcuts
    }

    var layout: QuickAccessViewContentLayout {
        switch self {
        case .shortcuts:
            .footerOnly
        case .noResults:
            .contentWithFooter
        case .locked, .syncError, .itemContent, .skippedItemDetails, .errorMessage:
            .contentOnly
        }
    }
}
