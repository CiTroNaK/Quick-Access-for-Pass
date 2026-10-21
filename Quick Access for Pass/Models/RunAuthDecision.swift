import Foundation
import GRDB

nonisolated struct RunAuthDecision: Codable, Sendable, FetchableRecord, PersistableRecord, Identifiable {
    let id: Int64
    let matchType: String
    let matchValue: String
    let commandText: String
    let appIdentifier: String
    let profileSlug: String
    var expiresAt: Date?
    var allowed: Bool
    var appTeamID: String?

    static let databaseTableName = "runAuthDecisions"
}
