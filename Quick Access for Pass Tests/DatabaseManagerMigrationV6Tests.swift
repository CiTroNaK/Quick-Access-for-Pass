import Testing
import Foundation
import GRDB
@testable import Quick_Access_for_Pass

@Suite("DatabaseManager Migration v6")
struct DatabaseManagerMigrationV6Tests {
    private func makeTestDB() throws -> DatabaseManager {
        try DatabaseManager(inMemory: true, passphrase: Data("test-key-for-migration-v6".utf8))
    }

    @Test func sshDecisionSupportsNilExpiresAt() throws {
        let db = try makeTestDB()
        try db.saveDecision(
            appIdentifier: "TEAM.com.test",
            keyFingerprint: "SHA256:forever",
            expiresAt: nil,
            appTeamID: "TEAM"
        )
        let found = try db.findValidDecision(
            appIdentifier: "TEAM.com.test",
            keyFingerprint: "SHA256:forever"
        )
        #expect(found != nil)
        #expect(found?.expiresAt == nil)
        #expect(found?.appTeamID == "TEAM")
    }

    @Test func runDecisionSupportsNilExpiresAt() throws {
        let db = try makeTestDB()
        try db.saveRunDecision(
            appIdentifier: "TEAM.com.test",
            subcommand: "git pull",
            profileSlug: "prod",
            expiresAt: nil,
            appTeamID: "TEAM"
        )
        let found = try db.findValidRunDecision(
            appIdentifier: "TEAM.com.test",
            subcommand: "git pull",
            profileSlug: "prod"
        )
        #expect(found != nil)
        #expect(found?.expiresAt == nil)
    }

    @Test func sshNilDecisionSurvivesPurge() throws {
        let db = try makeTestDB()
        try db.saveDecision(
            appIdentifier: "app.keep",
            keyFingerprint: "SHA256:keep",
            expiresAt: nil
        )
        try db.saveDecision(
            appIdentifier: "app.drop",
            keyFingerprint: "SHA256:drop",
            expiresAt: Date().addingTimeInterval(-100)
        )
        try db.cleanupExpiredDecisions()
        let remaining = try db.allAuthDecisions()
        #expect(remaining.count == 1)
        #expect(remaining[0].appIdentifier == "app.keep")
    }

    @Test func runNilDecisionSurvivesPurge() throws {
        let db = try makeTestDB()
        try db.saveRunDecision(
            appIdentifier: "app.keep", subcommand: "sub", profileSlug: "p",
            expiresAt: nil
        )
        try db.saveRunDecision(
            appIdentifier: "app.drop", subcommand: "sub", profileSlug: "p",
            expiresAt: Date().addingTimeInterval(-100)
        )
        try db.cleanupExpiredRunDecisions()
        let remaining = try db.allRunAuthDecisions()
        #expect(remaining.count == 1)
        #expect(remaining[0].appIdentifier == "app.keep")
    }

    @Test func sshDecisionsOrderPutsNilLast() throws {
        let db = try makeTestDB()
        try db.saveDecision(
            appIdentifier: "app.forever", keyFingerprint: "k1",
            expiresAt: nil
        )
        try db.saveDecision(
            appIdentifier: "app.soon", keyFingerprint: "k2",
            expiresAt: Date().addingTimeInterval(60)
        )
        try db.saveDecision(
            appIdentifier: "app.later", keyFingerprint: "k3",
            expiresAt: Date().addingTimeInterval(3600)
        )
        let all = try db.allAuthDecisions()
        #expect(all.map(\.appIdentifier) == ["app.soon", "app.later", "app.forever"])
    }

    @Test func runDecisionsOrderPutsNilLast() throws {
        let db = try makeTestDB()
        try db.saveRunDecision(
            appIdentifier: "app.forever", subcommand: "s", profileSlug: "p",
            expiresAt: nil
        )
        try db.saveRunDecision(
            appIdentifier: "app.soon", subcommand: "s", profileSlug: "p2",
            expiresAt: Date().addingTimeInterval(60)
        )
        let all = try db.allRunAuthDecisions()
        #expect(all.map(\.appIdentifier) == ["app.soon", "app.forever"])
    }
}
