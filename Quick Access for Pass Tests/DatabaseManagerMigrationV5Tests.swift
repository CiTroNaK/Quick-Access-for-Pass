import Testing
import Foundation
import GRDB
@testable import Quick_Access_for_Pass

@Suite("DatabaseManager Migration v5")
struct DatabaseManagerMigrationV5Tests {
    private func makeTestDB() throws -> DatabaseManager {
        try DatabaseManager(inMemory: true, passphrase: Data("test-key-for-migration-v5".utf8))
    }

    @Test func v5SupportsSSHAuthDecisionTeamID() throws {
        let db = try makeTestDB()
        try db.saveDecision(appIdentifier: "TEAM.com.test", keyFingerprint: "SHA256:def", expiresAt: Date().addingTimeInterval(3600), appTeamID: "TEAM")
        let found = try db.findValidDecision(appIdentifier: "TEAM.com.test", keyFingerprint: "SHA256:def")
        #expect(found?.appTeamID == "TEAM")
    }

    @Test func v5SupportsRunAuthDecisionTeamID() throws {
        let db = try makeTestDB()
        try db.saveRunDecision(appIdentifier: "TEAM.com.test", subcommand: "git pull", profileSlug: "prod", expiresAt: Date().addingTimeInterval(3600), appTeamID: "TEAM")
        let found = try db.findValidRunDecision(appIdentifier: "TEAM.com.test", subcommand: "git pull", profileSlug: "prod")
        #expect(found?.appTeamID == "TEAM")
    }

    @Test func v5SupportsBatchModeDecisionIdentityFields() throws {
        let db = try makeTestDB()
        try db.saveBatchModeDecision(keyFingerprint: "SHA256:abc", host: "github.com", keyName: "id_ed25519", allowed: true, appIdentifier: "TEAM.com.test", appTeamID: "TEAM")
        let found = try db.findBatchModeDecision(keyFingerprint: "SHA256:abc", host: "github.com")
        #expect(found?.appIdentifier == "TEAM.com.test")
        #expect(found?.appTeamID == "TEAM")
    }

    @Test func appTeamIDIsNullable() throws {
        let db = try makeTestDB()
        try db.saveDecision(appIdentifier: "TEAM.com.test", keyFingerprint: "SHA256:noTeam", expiresAt: Date().addingTimeInterval(3600), appTeamID: nil)
        let found = try db.findValidDecision(appIdentifier: "TEAM.com.test", keyFingerprint: "SHA256:noTeam")
        #expect(found?.appTeamID == nil)
    }
}
