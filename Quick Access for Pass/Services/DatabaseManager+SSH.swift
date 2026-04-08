import Foundation
import GRDB

// MARK: - SSH Auth Decisions

nonisolated extension DatabaseManager {
    func findValidDecision(appIdentifier: String, keyFingerprint: String) throws -> SSHAuthDecision? {
        try reader.read { db in
            try SSHAuthDecision
                .filter(Column("appIdentifier") == appIdentifier)
                .filter(Column("keyFingerprint") == keyFingerprint)
                .filter(Column("expiresAt") == nil || Column("expiresAt") > Date())
                .fetchOne(db)
        }
    }

    func saveDecision(appIdentifier: String, keyFingerprint: String, expiresAt: Date?, appTeamID: String? = nil) throws {
        try writer.write { db in
            let decision = SSHAuthDecision(
                appIdentifier: appIdentifier,
                keyFingerprint: keyFingerprint,
                expiresAt: expiresAt,
                appTeamID: appTeamID
            )
            try decision.save(db, onConflict: .replace)
        }
    }

    func cleanupExpiredDecisions() throws {
        _ = try writer.write { db in
            try SSHAuthDecision
                .filter(Column("expiresAt") != nil && Column("expiresAt") <= Date())
                .deleteAll(db)
        }
    }

    func allAuthDecisions() throws -> [SSHAuthDecision] {
        try reader.read { db in
            try SSHAuthDecision
                .filter(Column("expiresAt") == nil || Column("expiresAt") > Date())
                .order(sql: "(expiresAt IS NULL) ASC, expiresAt ASC")
                .fetchAll(db)
        }
    }

    func removeAuthDecision(appIdentifier: String, keyFingerprint: String) throws {
        _ = try writer.write { db in
            try SSHAuthDecision
                .filter(Column("appIdentifier") == appIdentifier)
                .filter(Column("keyFingerprint") == keyFingerprint)
                .deleteAll(db)
        }
    }
}

// MARK: - SSH BatchMode Decisions

nonisolated extension DatabaseManager {
    func findBatchModeDecision(keyFingerprint: String, host: String) throws -> SSHBatchModeDecision? {
        try reader.read { db in
            try SSHBatchModeDecision.fetchOne(db, key: ["keyFingerprint": keyFingerprint, "host": host])
        }
    }

    func saveBatchModeDecision(
        keyFingerprint: String,
        host: String,
        keyName: String?,
        allowed: Bool,
        appIdentifier: String? = nil,
        appTeamID: String? = nil
    ) throws {
        try writer.write { db in
            let decision = SSHBatchModeDecision(
                keyFingerprint: keyFingerprint,
                host: host,
                keyName: keyName,
                allowed: allowed,
                createdAt: Date(),
                appIdentifier: appIdentifier,
                appTeamID: appTeamID
            )
            try decision.save(db, onConflict: .replace)
        }
    }

    func removeBatchModeDecision(keyFingerprint: String, host: String) throws {
        _ = try writer.write { db in
            try SSHBatchModeDecision
                .filter(Column("keyFingerprint") == keyFingerprint)
                .filter(Column("host") == host)
                .deleteAll(db)
        }
    }

    func allBatchModeDecisions() throws -> [SSHBatchModeDecision] {
        try reader.read { db in
            try SSHBatchModeDecision.order(Column("createdAt").desc).fetchAll(db)
        }
    }
}
