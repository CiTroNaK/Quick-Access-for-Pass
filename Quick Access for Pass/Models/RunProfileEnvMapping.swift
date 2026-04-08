import Foundation
import GRDB

nonisolated struct RunProfileEnvMapping: Codable, Sendable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    let profileId: Int64
    let envVariable: String
    let secretReference: String

    static let databaseTableName = "runProfileEnvMappings"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
