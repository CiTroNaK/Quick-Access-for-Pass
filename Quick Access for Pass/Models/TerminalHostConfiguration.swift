import Foundation

nonisolated struct TerminalHostConfiguration: Codable, Identifiable, Equatable, Sendable {
    nonisolated enum Provider: String, Codable, Sendable { case generic, herdr }
    let id: String
    var executablePath: String
    var displayName: String
    var isEnabled: Bool
    var provider: Provider
    var showPaneDetails: Bool
    var isAutomaticallyDetected: Bool
}
