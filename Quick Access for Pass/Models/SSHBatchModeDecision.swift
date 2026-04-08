import Foundation
import GRDB

nonisolated struct SSHBatchModeDecision: Codable, Sendable, FetchableRecord, PersistableRecord {
    let keyFingerprint: String
    let host: String
    var keyName: String?
    var allowed: Bool
    var createdAt: Date
    var appIdentifier: String?
    var appTeamID: String?

    var compositeKey: String { "\(keyFingerprint):\(host)" }

    static let databaseTableName = "sshBatchModeDecisions"
}
