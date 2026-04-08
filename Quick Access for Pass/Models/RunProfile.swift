import Foundation
import GRDB

nonisolated struct RunProfile: Codable, Sendable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    let name: String
    let slug: String
    /// How long resolved secrets are cached in memory. Raw value of RememberDuration.
    var cacheDuration: String
    var createdAt: Date

    static let databaseTableName = "runProfiles"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
