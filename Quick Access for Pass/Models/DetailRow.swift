import Foundation

/// Flat, SwiftUI-renderable row model for `ItemDetailView`. Produced by
/// `QuickAccessViewModel.rows(for:)`; consumed by the view's `ForEach`.
///
/// `.sectionHeader` rows are non-selectable separators used inside
/// `.custom` items; arrow-key traversal skips them.
nonisolated enum DetailRow: Sendable, Identifiable, Equatable {
    case namedAction(action: ItemAction, label: String, shortcut: String)
    case field(key: FieldKey, label: String, isSensitive: Bool)
    case sectionHeader(name: String, id: String)
    case offlineAvailability(OfflineItemAvailability)
    case keepOfflineIndividually

    var id: String {
        switch self {
        case .namedAction(let action, _, _):
            return "named:\(action)"
        case .field(let key, _, _):
            return "field:\(Self.fieldStableId(for: key))"
        case .sectionHeader(_, let id):
            return "section:\(id)"
        case .offlineAvailability:
            return "offlineAvailability"
        case .keepOfflineIndividually:
            return "keepOfflineIndividually"
        }
    }

    var isSelectable: Bool {
        switch self {
        case .namedAction, .field: true
        case .sectionHeader: false
        case .offlineAvailability, .keepOfflineIndividually: true
        }
    }

    private static func fieldStableId(for key: FieldKey) -> String {
        key.stableIdentifier
    }
}
