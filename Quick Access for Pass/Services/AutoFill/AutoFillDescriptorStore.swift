import Foundation
import GRDB
import Security

nonisolated protocol AutoFillDescriptorStoring: Sendable {
    func descriptor(id: UUID) async throws -> AutoFillCredentialDescriptor?
    func candidates(for query: AutoFillCandidateQuery) async throws -> [AutoFillCandidate]
}

extension AutoFillDescriptorStoring {
    func candidates(for query: AutoFillCandidateQuery) async throws -> [AutoFillCandidate] {
        throw AutoFillProtocolError.malformedMessage
    }
}

/// Host-only read-only lookup for AutoFill descriptors in the local encrypted database.
actor AutoFillDescriptorStore: AutoFillDescriptorStoring {
    enum Error: Swift.Error, LocalizedError, Equatable {
        case deviceLocked
        case passphraseMissing

        var errorDescription: String? {
            switch self {
            case .deviceLocked:
                String(localized: "Unlock this Mac and try AutoFill again.")
            case .passphraseMissing:
                String(localized: "The host database passphrase is unavailable.")
            }
        }
    }

    private let databaseURL: URL
    private let keychainService: KeychainService
    private let didOpenDatabase: @Sendable () -> Void
    private var database: DatabaseQueue?

    init(
        databaseURL: URL,
        keychainService: KeychainService = KeychainService(),
        didOpenDatabase: @escaping @Sendable () -> Void = {}
    ) {
        self.databaseURL = databaseURL
        self.keychainService = keychainService
        self.didOpenDatabase = didOpenDatabase
    }

    func descriptor(id: UUID) async throws -> AutoFillCredentialDescriptor? {
        let database = try openDatabaseIfNeeded()
        return try await database.read { connection in
            try AutoFillCredentialDescriptor.fetchOne(connection, key: id)
        }
    }

    func candidates(for query: AutoFillCandidateQuery) async throws -> [AutoFillCandidate] {
        let database = try openDatabaseIfNeeded()
        return try await database.read { connection in
            switch query {
            case .site(_, let services, let kind, _, _):
                try Self.siteCandidates(for: services, kind: kind, in: connection)
            case .global(_, let search, let kind, _, _):
                try Self.globalCandidates(for: search, kind: kind, in: connection)
            }
        }
    }

    nonisolated private static func siteCandidates(
        for services: [AutoFillServiceIdentifier],
        kind: AutoFillValueKind,
        in connection: Database
    ) throws -> [AutoFillCandidate] {
        guard !services.isEmpty,
              services.count <= AutoFillCandidateQuery.maximumServiceIdentifiers else {
            throw AutoFillProtocolError.malformedMessage
        }
        var candidates: [AutoFillCandidate] = []
        var seen = Set<UUID>()
        for (tier, service) in services.enumerated() {
            let rows: [Row]
            switch service.kind {
            case .domain, .url:
                guard let host = AutoFillServiceIdentifier.normalizedHost(for: service) else {
                    throw AutoFillProtocolError.malformedMessage
                }
                rows = try Row.fetchAll(
                    connection,
                    sql: """
                        SELECT id, title, username FROM autoFillDescriptors
                        WHERE serviceIdentifier = ? AND (? = 'password' OR hasTOTP = 1)
                        ORDER BY title, username, id LIMIT ?
                        """,
                    arguments: [host, kind.rawValue, AutoFillCandidate.maximumCandidates]
                )
            case .app:
                rows = try Row.fetchAll(
                    connection,
                    sql: """
                        SELECT descriptor.id, descriptor.title, descriptor.username
                        FROM autoFillAppAssociations AS association
                        JOIN autoFillDescriptors AS descriptor ON descriptor.id = association.descriptorID
                        WHERE association.serviceKind = ? AND association.serviceIdentifier = ?
                          AND (? = 'password' OR descriptor.hasTOTP = 1)
                        ORDER BY descriptor.title, descriptor.username, descriptor.id LIMIT ?
                        """,
                    arguments: [service.kind.rawValue, service.identifier, kind.rawValue, AutoFillCandidate.maximumCandidates]
                )
            }
            for row in rows where candidates.count < AutoFillCandidate.maximumCandidates {
                let descriptorID: UUID = row["id"]
                guard seen.insert(descriptorID).inserted else { continue }
                candidates.append(AutoFillCandidate(
                    descriptorID: descriptorID,
                    title: row["title"],
                    username: row["username"],
                    kind: kind,
                    matchTier: tier
                ))
            }
        }
        return candidates
    }

    nonisolated private static func globalCandidates(
        for search: String,
        kind: AutoFillValueKind,
        in connection: Database
    ) throws -> [AutoFillCandidate] {
        guard let normalized = AutoFillCandidateQuery.normalizedSearch(search) else {
            throw AutoFillProtocolError.malformedMessage
        }
        let rows = try Row.fetchAll(
            connection,
            sql: """
                SELECT id, title, username FROM autoFillDescriptors
                WHERE (title LIKE ? COLLATE NOCASE OR username LIKE ? COLLATE NOCASE)
                  AND (? = 'password' OR hasTOTP = 1)
                ORDER BY title, username, id LIMIT ?
                """,
            arguments: ["%\(normalized)%", "%\(normalized)%", kind.rawValue, AutoFillCandidate.maximumCandidates]
        )
        return rows.compactMap { row in
            let descriptorID: UUID = row["id"]
            return AutoFillCandidate(
                descriptorID: descriptorID,
                title: row["title"],
                username: row["username"],
                kind: kind,
                matchTier: 0
            )
        }
    }

    private func openDatabaseIfNeeded() throws -> DatabaseQueue {
        if let database {
            return database
        }

        let passphrase: Data
        do {
            guard let existing = try keychainService.retrievePassphrase() else {
                throw Error.passphraseMissing
            }
            passphrase = existing
        } catch KeychainError.retrieveFailed(errSecInteractionNotAllowed) {
            throw Error.deviceLocked
        }

        var configuration = Configuration()
        configuration.readonly = true
        configuration.prepareDatabase { connection in
            try connection.usePassphrase(passphrase)
        }
        let opened = try DatabaseQueue(
            path: databaseURL.path,
            configuration: configuration
        )
        try opened.read { connection in
            _ = try Int.fetchOne(connection, sql: "SELECT count(*) FROM sqlite_master")
        }
        database = opened
        didOpenDatabase()
        return opened
    }
}
