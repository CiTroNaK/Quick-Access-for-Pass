import Foundation
import GRDB

nonisolated struct SSHAuthDecision: Codable, Sendable, FetchableRecord, PersistableRecord {
    let appIdentifier: String
    let keyFingerprint: String
    var expiresAt: Date?
    var allowed: Bool = true
    var appTeamID: String?

    static let databaseTableName = "sshAuthDecisions"

    var compositeKey: String { "\(appIdentifier)|\(keyFingerprint)" }
}
