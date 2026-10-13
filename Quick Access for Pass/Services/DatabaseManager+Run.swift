import Foundation
import GRDB

nonisolated enum RunProfileError: Error, LocalizedError, Equatable {
    case reservedSlug

    var errorDescription: String? {
        switch self {
        case .reservedSlug:
            return String(localized: "The slug \"\(RunProxyProbeConstants.reservedPingSlug)\" is reserved for internal health checks. Choose a different slug.")
        }
    }
}

// MARK: - Run Profiles

nonisolated extension DatabaseManager {
    func allRunProfiles() throws -> [RunProfile] {
        try reader.read { db in
            try RunProfile.order(Column("name").asc).fetchAll(db)
        }
    }

    func findRunProfile(slug: String) throws -> RunProfile? {
        try reader.read { db in
            try RunProfile.filter(Column("slug") == slug).fetchOne(db)
        }
    }

    func saveRunProfile(_ profile: RunProfile, mappings: [RunProfileEnvMapping]) throws -> RunProfile {
        guard profile.slug != RunProxyProbeConstants.reservedPingSlug else {
            throw RunProfileError.reservedSlug
        }
        return try writer.write { db in
            var saved = profile
            if saved.id == nil {
                try saved.insert(db)
                saved.id = db.lastInsertedRowID
            } else {
                try saved.update(db)
            }
            let profileId = saved.id!
            // Delete existing mappings and re-insert
            try RunProfileEnvMapping.filter(Column("profileId") == profileId).deleteAll(db)
            for mapping in mappings {
                // GRDB migration convention
                // swiftlint:disable:next identifier_name
                let m = RunProfileEnvMapping(
                    id: nil,
                    profileId: profileId,
                    envVariable: mapping.envVariable,
                    secretReference: mapping.secretReference
                )
                try m.insert(db)
            }
            return saved
        }
    }

    func deleteRunProfile(id: Int64) throws {
        _ = try writer.write { db in
            try RunProfile.deleteOne(db, key: id)
        }
    }

    func envMappings(forProfileId profileId: Int64) throws -> [RunProfileEnvMapping] {
        try reader.read { db in
            try RunProfileEnvMapping
                .filter(Column("profileId") == profileId)
                .fetchAll(db)
        }
    }
}

// MARK: - Run Auth Decisions

nonisolated extension DatabaseManager {
    func findValidRunDecision(
        appIdentifier: String,
        identity: RunAuthorizationIdentity,
        profileSlug: String
    ) throws -> RunAuthDecision? {
        try reader.read { db in
            try RunAuthDecision
                .filter(Column("appIdentifier") == appIdentifier)
                .filter(Column("profileSlug") == profileSlug)
                .filter(Column("matchType") == identity.matchType.rawValue)
                .filter(Column("matchValue") == identity.matchValue)
                .filter(Column("expiresAt") == nil || Column("expiresAt") > Date())
                .fetchOne(db)
        }
    }

    func saveRunDecision(
        appIdentifier: String,
        scope: RunAuthorizationScope,
        profileSlug: String,
        expiresAt: Date?,
        allowed: Bool,
        appTeamID: String? = nil
    ) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO runAuthDecisions
                        (matchType, matchValue, commandText, appIdentifier, profileSlug, expiresAt, allowed, appTeamID)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(appIdentifier, profileSlug, matchType, matchValue) DO UPDATE SET
                        commandText = excluded.commandText,
                        expiresAt = excluded.expiresAt,
                        allowed = excluded.allowed,
                        appTeamID = excluded.appTeamID
                    """,
                arguments: [
                    scope.identity.matchType.rawValue, scope.identity.matchValue, scope.label,
                    appIdentifier, profileSlug, expiresAt, allowed, appTeamID
                ]
            )
        }
    }

    func allRunAuthDecisions() throws -> [RunAuthDecision] {
        try reader.read { db in
            try RunAuthDecision
                .filter(Column("expiresAt") == nil || Column("expiresAt") > Date())
                .order(sql: "(expiresAt IS NULL) ASC, expiresAt ASC")
                .fetchAll(db)
        }
    }

    func removeRunAuthDecision(id: Int64) throws {
        _ = try writer.write { db in
            try RunAuthDecision.deleteOne(db, key: id)
        }
    }

    func cleanupExpiredRunDecisions() throws {
        _ = try writer.write { db in
            try RunAuthDecision
                .filter(Column("expiresAt") != nil && Column("expiresAt") <= Date())
                .deleteAll(db)
        }
    }
}
