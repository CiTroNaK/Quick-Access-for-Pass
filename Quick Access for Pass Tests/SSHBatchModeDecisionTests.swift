import Testing
import Foundation
@testable import Quick_Access_for_Pass

@Suite("SSHBatchModeDecision Tests")
struct SSHBatchModeDecisionTests {

    @Test func noDecisionByDefault() throws {
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let decision = try db.findBatchModeDecision(keyFingerprint: "abc123", host: "github.com")
        #expect(decision == nil)
    }

    @Test func saveAndFindAllowedDecision() throws {
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try db.saveBatchModeDecision(keyFingerprint: "abc123", host: "github.com", keyName: "my-key", allowed: true)
        let decision = try db.findBatchModeDecision(keyFingerprint: "abc123", host: "github.com")
        #expect(decision != nil)
        #expect(decision?.allowed == true)
        #expect(decision?.host == "github.com")
        #expect(decision?.keyName == "my-key")
    }

    @Test func saveAndFindDeniedDecision() throws {
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try db.saveBatchModeDecision(keyFingerprint: "abc123", host: "evil.com", keyName: "bad-key", allowed: false)
        let decision = try db.findBatchModeDecision(keyFingerprint: "abc123", host: "evil.com")
        #expect(decision != nil)
        #expect(decision?.allowed == false)
    }

    @Test func upsertOverwritesExisting() throws {
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try db.saveBatchModeDecision(keyFingerprint: "abc123", host: "github.com", keyName: "my-key", allowed: false)
        try db.saveBatchModeDecision(keyFingerprint: "abc123", host: "github.com", keyName: "my-key", allowed: true)
        let decision = try db.findBatchModeDecision(keyFingerprint: "abc123", host: "github.com")
        #expect(decision?.allowed == true)
    }

    @Test func removeDecision() throws {
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try db.saveBatchModeDecision(keyFingerprint: "abc123", host: "github.com", keyName: "my-key", allowed: true)
        try db.removeBatchModeDecision(keyFingerprint: "abc123", host: "github.com")
        #expect(try db.findBatchModeDecision(keyFingerprint: "abc123", host: "github.com") == nil)
    }

    @Test func allDecisionsReturnsSavedEntries() throws {
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try db.saveBatchModeDecision(keyFingerprint: "key1", host: "github.com", keyName: "key-1", allowed: true)
        try db.saveBatchModeDecision(keyFingerprint: "key2", host: "gitlab.com", keyName: "key-2", allowed: false)
        let all = try db.allBatchModeDecisions()
        #expect(all.count == 2)
    }

    @Test func sameKeyDifferentHostsAreSeparate() throws {
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try db.saveBatchModeDecision(keyFingerprint: "key1", host: "github.com", keyName: "k1", allowed: true)
        try db.saveBatchModeDecision(keyFingerprint: "key1", host: "gitlab.com", keyName: "k1", allowed: false)
        #expect(try db.findBatchModeDecision(keyFingerprint: "key1", host: "github.com")?.allowed == true)
        #expect(try db.findBatchModeDecision(keyFingerprint: "key1", host: "gitlab.com")?.allowed == false)
    }

    @Test func differentFingerprintsAreSeparate() throws {
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try db.saveBatchModeDecision(keyFingerprint: "key1", host: "github.com", keyName: "k1", allowed: true)
        #expect(try db.findBatchModeDecision(keyFingerprint: "key2", host: "github.com") == nil)
    }
}
