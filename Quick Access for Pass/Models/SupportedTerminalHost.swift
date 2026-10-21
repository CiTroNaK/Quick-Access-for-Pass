import Foundation

/// A terminal product with an explicitly supported integration.
nonisolated enum SupportedTerminalHost: String, CaseIterable, Identifiable, Sendable {
    case herdr

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .herdr: "Herdr"
        }
    }
}
