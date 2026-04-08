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
    func findValidRunDecision(appIdentifier: String, subcommand: String, profileSlug: String) throws -> RunAuthDecision? {
        try reader.read { db in
            try RunAuthDecision
                .filter(Column("appIdentifier") == appIdentifier)
                .filter(Column("subcommand") == subcommand)
                .filter(Column("profileSlug") == profileSlug)
                .filter(Column("expiresAt") == nil || Column("expiresAt") > Date())
                .fetchOne(db)
        }
    }

    func saveRunDecision(appIdentifier: String, subcommand: String, profileSlug: String, expiresAt: Date?, appTeamID: String? = nil) throws {
        try writer.write { db in
            let decision = RunAuthDecision(
                appIdentifier: appIdentifier,
                subcommand: subcommand,
                profileSlug: profileSlug,
                expiresAt: expiresAt,
                appTeamID: appTeamID
            )
            try decision.save(db, onConflict: .replace)
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

    func removeRunAuthDecision(appIdentifier: String, subcommand: String, profileSlug: String) throws {
        _ = try writer.write { db in
            try RunAuthDecision
                .filter(Column("appIdentifier") == appIdentifier)
                .filter(Column("subcommand") == subcommand)
                .filter(Column("profileSlug") == profileSlug)
                .deleteAll(db)
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
