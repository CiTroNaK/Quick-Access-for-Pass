import Foundation

nonisolated enum SettingsTab: String, CaseIterable, Sendable {
    case general
    case shortcuts
    case security
    case offline
    case passCLI
    case ssh
    case run
    case integrations
    case about
}
