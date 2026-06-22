import Foundation

nonisolated enum SettingsTab: String, CaseIterable, Sendable {
    case general
    case shortcuts
    case security
    case passCLI
    case ssh
    case run
    case about
}
