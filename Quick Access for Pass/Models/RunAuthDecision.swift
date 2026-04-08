import Foundation
import GRDB

nonisolated struct RunAuthDecision: Codable, Sendable, FetchableRecord, PersistableRecord {
    let appIdentifier: String
    let subcommand: String
    let profileSlug: String
    var expiresAt: Date?
    var appTeamID: String?

    static let databaseTableName = "runAuthDecisions"

    var compositeKey: String { "\(appIdentifier)|\(subcommand)|\(profileSlug)" }
}
