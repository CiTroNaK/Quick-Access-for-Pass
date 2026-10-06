import Foundation
import GRDB

/// Shared SQLCipher and SQLite protections required by every host database connection.
nonisolated enum EncryptedDatabaseConfiguration {
    enum Error: Swift.Error, Equatable {
        case unavailableProtection
    }

    static func prepare(_ database: Database, passphrase: Data) throws {
        try database.execute(sql: "PRAGMA cipher_memory_security = ON")
        guard try Int.fetchOne(database, sql: "PRAGMA cipher_memory_security") == 1 else {
            throw Error.unavailableProtection
        }

        try database.usePassphrase(passphrase)
        try database.execute(sql: "PRAGMA secure_delete = ON")
        try database.execute(sql: "PRAGMA temp_store = MEMORY")
        guard try Int.fetchOne(database, sql: "PRAGMA secure_delete") == 1,
              try Int.fetchOne(database, sql: "PRAGMA temp_store") == 2,
              try Int.fetchOne(database, sql: "PRAGMA foreign_keys") == 1,
              try String.fetchOne(database, sql: "PRAGMA cipher_version")?.isEmpty == false else {
            throw Error.unavailableProtection
        }
    }
}
