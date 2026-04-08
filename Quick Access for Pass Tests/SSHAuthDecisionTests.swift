import Testing
import Foundation
@testable import Quick_Access_for_Pass

@Suite("SSHAuthDecision Tests")
struct SSHAuthDecisionTests {
    // Each test creates its own DatabaseManager with in-memory DB

    @Test func noDecisionByDefault() throws {
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let decision = try db.findValidDecision(appIdentifier: "com.test.app", keyFingerprint: "abc123")
        #expect(decision == nil)
    }

    @Test func saveAndFindDecision() throws {
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let expiry = Date().addingTimeInterval(300)
        try db.saveDecision(appIdentifier: "com.test.app", keyFingerprint: "abc123", expiresAt: expiry)
        let decision = try db.findValidDecision(appIdentifier: "com.test.app", keyFingerprint: "abc123")
        #expect(decision != nil)
        #expect(decision?.appIdentifier == "com.test.app")
        #expect(decision?.keyFingerprint == "abc123")
    }

    @Test func expiredDecisionNotReturned() throws {
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let expiry = Date().addingTimeInterval(-10)
        try db.saveDecision(appIdentifier: "com.test.app", keyFingerprint: "abc123", expiresAt: expiry)
        let decision = try db.findValidDecision(appIdentifier: "com.test.app", keyFingerprint: "abc123")
        #expect(decision == nil)
    }

    @Test func upsertOverwritesExisting() throws {
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try db.saveDecision(appIdentifier: "com.test.app", keyFingerprint: "abc123", expiresAt: Date().addingTimeInterval(60))
        let expiry2 = Date().addingTimeInterval(3600)
        try db.saveDecision(appIdentifier: "com.test.app", keyFingerprint: "abc123", expiresAt: expiry2)
        let decision = try db.findValidDecision(appIdentifier: "com.test.app", keyFingerprint: "abc123")
        #expect(decision != nil)
        #expect(abs((decision?.expiresAt?.timeIntervalSinceReferenceDate ?? 0) - expiry2.timeIntervalSinceReferenceDate) < 1.0)
    }

    @Test func cleanupExpiredDecisions() throws {
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try db.saveDecision(appIdentifier: "app1", keyFingerprint: "key1", expiresAt: Date().addingTimeInterval(-100))
        try db.saveDecision(appIdentifier: "app2", keyFingerprint: "key2", expiresAt: Date().addingTimeInterval(300))
        try db.cleanupExpiredDecisions()
        #expect(try db.findValidDecision(appIdentifier: "app1", keyFingerprint: "key1") == nil)
        #expect(try db.findValidDecision(appIdentifier: "app2", keyFingerprint: "key2") != nil)
    }

    @Test func differentKeysAreSeparate() throws {
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try db.saveDecision(appIdentifier: "com.test.app", keyFingerprint: "key1", expiresAt: Date().addingTimeInterval(300))
        #expect(try db.findValidDecision(appIdentifier: "com.test.app", keyFingerprint: "key2") == nil)
    }

    @Test func triggerCommandsAreSeparate() throws {
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        // "git fetch --all" allowed for a day
        try db.saveDecision(appIdentifier: "com.mitchellh.ghostty:github.com:git fetch --all", keyFingerprint: "key1", expiresAt: Date().addingTimeInterval(86400))
        // "git push" should NOT be covered
        #expect(try db.findValidDecision(appIdentifier: "com.mitchellh.ghostty:github.com:git push", keyFingerprint: "key1") == nil)
        // "git fetch --all" should be covered
        #expect(try db.findValidDecision(appIdentifier: "com.mitchellh.ghostty:github.com:git fetch --all", keyFingerprint: "key1") != nil)
        // Direct SSH (no trigger command) should NOT be covered
        #expect(try db.findValidDecision(appIdentifier: "com.mitchellh.ghostty:github.com", keyFingerprint: "key1") == nil)
    }

    @Test func allAuthDecisionsExcludesExpired() throws {
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try db.saveDecision(appIdentifier: "app1", keyFingerprint: "key1", expiresAt: Date().addingTimeInterval(300))
        try db.saveDecision(appIdentifier: "app2", keyFingerprint: "key2", expiresAt: Date().addingTimeInterval(-100))
        let all = try db.allAuthDecisions()
        #expect(all.count == 1)
        #expect(all[0].appIdentifier == "app1")
    }

    @Test func removeAuthDecision() throws {
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try db.saveDecision(appIdentifier: "app1", keyFingerprint: "key1", expiresAt: Date().addingTimeInterval(300))
        try db.saveDecision(appIdentifier: "app2", keyFingerprint: "key2", expiresAt: Date().addingTimeInterval(300))
        try db.removeAuthDecision(appIdentifier: "app1", keyFingerprint: "key1")
        let all = try db.allAuthDecisions()
        #expect(all.count == 1)
        #expect(all[0].appIdentifier == "app2")
    }
}
