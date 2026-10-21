import Foundation
import GRDB

/// Presentation metadata for a user-approved native-app AutoFill association.
nonisolated struct AutoFillAppAssociationDisplay: Equatable, Sendable {
    let serviceIdentifier: String
    let serviceDisplayName: String?
    let descriptorID: UUID
    let title: String
    let username: String
    let createdAt: Date
}

/// Host-only writer for explicit native-app-to-descriptor associations.
actor AutoFillAppAssociationStore {
    enum Error: Swift.Error, Equatable {
        case invalidService
        case descriptorNotFound
    }

    private let databaseManager: DatabaseManager

    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
    }

    func save(
        service: AutoFillServiceIdentifier,
        descriptorID: UUID,
        createdAt: Date
    ) async throws {
        guard service.kind == .app else { throw Error.invalidService }
        try await databaseManager.writer.write { db in
            guard try AutoFillCredentialDescriptor.fetchOne(db, key: descriptorID) != nil else {
                throw Error.descriptorNotFound
            }
            try db.execute(
                sql: """
                    INSERT INTO autoFillAppAssociations
                        (serviceIdentifier, serviceKind, descriptorID, serviceDisplayName, createdAt)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(serviceKind, serviceIdentifier) DO UPDATE SET
                        descriptorID = excluded.descriptorID,
                        serviceDisplayName = excluded.serviceDisplayName,
                        createdAt = excluded.createdAt
                    """,
                arguments: [
                    service.identifier,
                    service.kind.rawValue,
                    descriptorID,
                    service.displayName,
                    createdAt
                ]
            )
        }
    }

    func associations() async throws -> [AutoFillAppAssociationDisplay] {
        try await databaseManager.reader.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT association.serviceIdentifier, association.serviceDisplayName,
                           association.descriptorID, descriptor.title, descriptor.username,
                           association.createdAt
                    FROM autoFillAppAssociations AS association
                    JOIN autoFillDescriptors AS descriptor ON descriptor.id = association.descriptorID
                    WHERE association.serviceKind = ?
                    ORDER BY association.createdAt DESC, association.serviceIdentifier
                    """,
                arguments: [AutoFillServiceIdentifierKind.app.rawValue]
            )
            return rows.compactMap { row in
                let descriptorID: UUID = row["descriptorID"]
                return AutoFillAppAssociationDisplay(
                    serviceIdentifier: row["serviceIdentifier"],
                    serviceDisplayName: row["serviceDisplayName"],
                    descriptorID: descriptorID,
                    title: row["title"],
                    username: row["username"],
                    createdAt: row["createdAt"]
                )
            }
        }
    }

    func delete(service: AutoFillServiceIdentifier) async throws {
        guard service.kind == .app else { throw Error.invalidService }
        try await databaseManager.writer.write { db in
            try db.execute(
                sql: "DELETE FROM autoFillAppAssociations WHERE serviceKind = ? AND serviceIdentifier = ?",
                arguments: [service.kind.rawValue, service.identifier]
            )
        }
    }
}
