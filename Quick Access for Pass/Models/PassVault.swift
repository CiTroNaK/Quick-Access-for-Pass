import Foundation
import GRDB

nonisolated struct PassVault: Sendable, FetchableRecord, PersistableRecord, Identifiable {
    let id: String
    let name: String
    let shareId: String

    static let databaseTableName = "vaults"

    init(id: String, name: String, shareId: String? = nil) {
        self.id = id
        self.name = name
        self.shareId = shareId ?? id
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["name"] = name
        container["shareId"] = shareId
    }
}

extension PassVault: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, shareId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        shareId = try container.decodeIfPresent(String.self, forKey: .shareId) ?? id
    }
}

extension PassVault {
    init(from cliVault: CLIVault) {
        self.id = cliVault.vaultId
        self.name = cliVault.name
        self.shareId = cliVault.shareId
    }
}
