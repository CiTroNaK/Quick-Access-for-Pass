import Foundation
import GRDB

nonisolated struct PassVault: Codable, Sendable, FetchableRecord, PersistableRecord, Identifiable {
    let id: String
    let name: String

    static let databaseTableName = "vaults"
}

extension PassVault {
    init(from cliVault: CLIVault) {
        self.id = cliVault.shareId
        self.name = cliVault.name
    }
}
