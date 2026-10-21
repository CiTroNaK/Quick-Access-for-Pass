import Foundation

/// Derived matching data, deliberately excluded from saved preferences.
nonisolated struct TerminalHostMatchingEntry: Equatable, Sendable {
    let configuration: TerminalHostConfiguration
    let canonicalExecutablePath: String
}
