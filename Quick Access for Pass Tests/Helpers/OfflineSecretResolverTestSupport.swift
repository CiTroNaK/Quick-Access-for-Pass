import AppKit
import Foundation
import GRDB
import os
import Testing
@testable import Quick_Access_for_Pass

struct SelectedResolverFixture {
    let database: DatabaseManager
    let repository: OfflineSnapshotRepository
    let codec: OfflineSnapshotCodec
    let service: OfflineModeService
}

struct ResolverLive: OfflineSecretResolvingLive, OfflineItemViewing {
    let item: CLIItem?
    let error: CLIError?
    private let now: @Sendable () -> UInt64
    private let recordedDeadlines = OSAllocatedUnfairLock<[CLIExecutionDeadline]>(initialState: [])
    private let calls = OSAllocatedUnfairLock(initialState: 0)
    init(item: CLIItem? = nil, error: CLIError? = nil,
         now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.item = item
        self.error = error
        self.now = now
    }
    func deadlines() -> [CLIExecutionDeadline] { recordedDeadlines.withLock { $0 } }
    func callCount() -> Int { calls.withLock { $0 } }
    func viewItem(itemId: String, shareId: String, deadline: CLIExecutionDeadline) async throws -> CLIItem {
        try Task.checkCancellation()
        _ = try deadline.remainingSeconds(at: now())
        recordedDeadlines.withLock { $0.append(deadline) }
        return try await viewItem(itemId: itemId, shareId: shareId)
    }
    func getTotp(itemId: String, shareId: String, deadline: CLIExecutionDeadline) async throws -> String {
        try Task.checkCancellation()
        _ = try deadline.remainingSeconds(at: now())
        recordedDeadlines.withLock { $0.append(deadline) }
        return try await getTotp(itemId: itemId, shareId: shareId)
    }
    func viewItem(itemId: String, shareId: String) async throws -> CLIItem { calls.withLock { $0 += 1 }; if let error { throw error }; return item! }
    func getTotp(itemId: String, shareId: String) async throws -> String { calls.withLock { $0 += 1 }; if let error { throw error }; return "live" }
    func viewItem(itemId: String, shareId: String, timeout: TimeInterval) async throws -> CLIItem { try await viewItem(itemId: itemId, shareId: shareId) }
    func getTotp(itemId: String, shareId: String, timeout: TimeInterval) async throws -> String { try await getTotp(itemId: itemId, shareId: shareId) }
}

struct ResolverViewer: OfflineItemViewing {
    let totp: String
    let username: String
    let email: String
    func viewItem(itemId: String, shareId: String) async throws -> CLIItem {
        let object: [String: Any] = [
            "id": "item", "share_id": "share", "vault_id": "vault",
            "content": [
                "title": "", "note": "", "item_uuid": "content-item",
                "content": ["Login": ["username": username, "email": email, "password": "cached", "totp_uri": totp]]
            ],
            "state": "Active", "flags": [], "create_time": "", "modify_time": ""
        ]
        return try JSONDecoder().decode(
            CLIItem.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }
}

struct AutoReady: OfflineInitializationProviding { func isReady() async -> Bool { true } }

actor TimedLiveRecorder: OfflineSecretResolvingLive {
    private var recorded: [TimeInterval] = []
    private var calls = 0
    private let now: @Sendable () -> UInt64

    init(now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) { self.now = now }
    func viewItem(itemId: String, shareId: String) async throws -> CLIItem {
        calls += 1
        return try offlineTestCLIItem(id: itemId, vaultID: "vault", shareID: shareId, password: "live")
    }
    func getTotp(itemId: String, shareId: String) async throws -> String { calls += 1; return "000000" }
    func viewItem(itemId: String, shareId: String, timeout: TimeInterval) async throws -> CLIItem { recorded.append(timeout); return try await viewItem(itemId: itemId, shareId: shareId) }
    func getTotp(itemId: String, shareId: String, timeout: TimeInterval) async throws -> String { recorded.append(timeout); calls += 1; return "000000" }
    func viewItem(itemId: String, shareId: String, deadline: CLIExecutionDeadline) async throws -> CLIItem {
        let remaining = try deadline.remainingSeconds(at: now())
        recorded.append(remaining)
        return try await viewItem(itemId: itemId, shareId: shareId)
    }
    func getTotp(itemId: String, shareId: String, deadline: CLIExecutionDeadline) async throws -> String {
        recorded.append(try deadline.remainingSeconds(at: now()))
        calls += 1
        return "000000"
    }
    func timeouts() -> [TimeInterval] { recorded }
    func callCount() -> Int { calls }
}

struct NotReady: OfflineInitializationProviding {
    func isReady() async -> Bool { false }
}

actor AdvancingTimedLive: OfflineSecretResolvingLive {
    private let clock: OSAllocatedUnfairLock<UInt64>
    private var recorded: [TimeInterval] = []

    init(clock: OSAllocatedUnfairLock<UInt64>) { self.clock = clock }

    func viewItem(itemId: String, shareId: String) async throws -> CLIItem {
        try offlineTestCLIItem(id: itemId, vaultID: "vault", shareID: shareId, password: "live")
    }

    func getTotp(itemId: String, shareId: String) async throws -> String { "000000" }

    func viewItem(itemId: String, shareId: String, timeout: TimeInterval) async throws -> CLIItem {
        recorded.append(timeout)
        clock.withLock { $0 = 5_000_000_000 }
        return try await viewItem(itemId: itemId, shareId: shareId)
    }

    func getTotp(itemId: String, shareId: String, timeout: TimeInterval) async throws -> String {
        recorded.append(timeout)
        return "000000"
    }

    func viewItem(itemId: String, shareId: String, deadline: CLIExecutionDeadline) async throws -> CLIItem {
        recorded.append(try deadline.remainingSeconds(at: clock.withLock { $0 }))
        clock.withLock { $0 = 5_000_000_000 }
        return try await viewItem(itemId: itemId, shareId: shareId)
    }

    func getTotp(itemId: String, shareId: String, deadline: CLIExecutionDeadline) async throws -> String {
        recorded.append(try deadline.remainingSeconds(at: clock.withLock { $0 }))
        return "000000"
    }

    func timeouts() -> [TimeInterval] { recorded }
}

actor ComposedTOTPParseFailureLive: OfflineSecretResolvingLive {
    private let clock: OSAllocatedUnfairLock<UInt64>
    private var callDeadlines: [UInt64] = []

    init(clock: OSAllocatedUnfairLock<UInt64>) { self.clock = clock }

    func viewItem(itemId: String, shareId: String) async throws -> CLIItem { throw CLIError.timeout }
    func getTotp(itemId: String, shareId: String) async throws -> String { throw CLIError.timeout }
    func viewItem(itemId: String, shareId: String, timeout: TimeInterval) async throws -> CLIItem { throw CLIError.timeout }
    func getTotp(itemId: String, shareId: String, timeout: TimeInterval) async throws -> String { throw CLIError.timeout }
    func viewItem(itemId: String, shareId: String, deadline: CLIExecutionDeadline) async throws -> CLIItem {
        callDeadlines.append(deadline.uptimeNanoseconds)
        clock.withLock { $0 = 2_500_000_000 }
        return try offlineTestCLIItem(
            id: itemId, vaultID: "vault", shareID: shareId, password: "live",
            totp: "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&period=999999999"
        )
    }
    func getTotp(itemId: String, shareId: String, deadline: CLIExecutionDeadline) async throws -> String {
        callDeadlines.append(deadline.uptimeNanoseconds)
        clock.withLock { $0 = 3_100_000_000 }
        throw CLIError.parseError("malformed")
    }
    func deadlines() -> [UInt64] { callDeadlines }
}

actor PostDecodeGateCodec: OfflineSnapshotCoding {
    private let codec: OfflineSnapshotCodec
    private let gate: OfflineTestGate
    private let failure: OfflineSnapshotCodec.Error?

    init(codec: OfflineSnapshotCodec, gate: OfflineTestGate, failure: OfflineSnapshotCodec.Error? = nil) {
        self.codec = codec
        self.gate = gate
        self.failure = failure
    }

    func prepareSnapshot(from item: CLIItem, for request: OfflineSnapshotPreparationIdentity) async throws -> PreparedOfflineSnapshot {
        try await codec.prepareSnapshot(from: item, for: request)
    }

    func decodeSnapshot(_ snapshot: EncryptedOfflineSnapshot) async throws -> CLIItem {
        let item = try await codec.decodeSnapshot(snapshot)
        try await gate.wait()
        if let failure { throw failure }
        return item
    }
}

actor DecodeCountingCodec: OfflineSnapshotCoding {
    private let codec: any OfflineSnapshotCoding
    private var decodes = 0

    init(codec: any OfflineSnapshotCoding) { self.codec = codec }

    func prepareSnapshot(from item: CLIItem, for request: OfflineSnapshotPreparationIdentity) async throws -> PreparedOfflineSnapshot {
        try await codec.prepareSnapshot(from: item, for: request)
    }

    func decodeSnapshot(_ snapshot: EncryptedOfflineSnapshot) async throws -> CLIItem {
        decodes += 1
        return try await codec.decodeSnapshot(snapshot)
    }

    func decodeCount() -> Int { decodes }
}

actor PostDecodeReplacementGateCodec: OfflineSnapshotCoding {
    private let codec: OfflineSnapshotCodec
    private let gate: OfflineTestGate
    private let staleRevision: UUID
    private var revisions: [UUID] = []
    private var matches: [Bool] = []

    init(codec: OfflineSnapshotCodec, gate: OfflineTestGate, staleRevision: UUID) {
        self.codec = codec
        self.gate = gate
        self.staleRevision = staleRevision
    }

    func prepareSnapshot(from item: CLIItem, for request: OfflineSnapshotPreparationIdentity) async throws -> PreparedOfflineSnapshot {
        try await codec.prepareSnapshot(from: item, for: request)
    }

    func decodeSnapshot(_ snapshot: EncryptedOfflineSnapshot) async throws -> CLIItem {
        let item = try await codec.decodeSnapshot(snapshot)
        revisions.append(snapshot.identity.revision)
        if case .login(let login) = item.content.content { matches.append(login.username == "user") }
        else { matches.append(false) }
        if revisions.count == 1, snapshot.identity.revision == staleRevision { try await gate.wait() }
        return item
    }

    func decodedRevisions() -> [UUID] { revisions }
    func usernameMatches() -> [Bool] { matches }
}

actor ReplacementRaceCodec: OfflineSnapshotCoding {
    private let codec: OfflineSnapshotCodec
    private let staleRevision: UUID
    private let database: DatabaseManager
    private let replacement: EncryptedOfflineSnapshot
    private var replaced = false

    init(
        codec: OfflineSnapshotCodec,
        staleRevision: UUID,
        database: DatabaseManager,
        replacement: EncryptedOfflineSnapshot
    ) {
        self.codec = codec
        self.staleRevision = staleRevision
        self.database = database
        self.replacement = replacement
    }

    func prepareSnapshot(from item: CLIItem, for request: OfflineSnapshotPreparationIdentity) async throws -> PreparedOfflineSnapshot {
        try await codec.prepareSnapshot(from: item, for: request)
    }

    func decodeSnapshot(_ snapshot: EncryptedOfflineSnapshot) async throws -> CLIItem {
        if snapshot.identity.revision == staleRevision, !replaced {
            replaced = true
            try await database.writer.write { db in
                try db.execute(
                    sql: """
                    UPDATE offlineSnapshots
                    SET schemaVersion = ?, snapshotRevision = ?, keyFingerprint = ?, encryptedPayload = ?
                    WHERE vaultId = ? AND itemId = ?
                    """,
                    arguments: [
                        replacement.identity.key.schemaVersion,
                        replacement.identity.revision.uuidString,
                        replacement.identity.keyFingerprint,
                        replacement.payload,
                        replacement.identity.key.vaultId,
                        replacement.identity.key.itemId
                    ]
                )
            }
            throw OfflineSnapshotCodec.Error.corruptSnapshot
        }
        return try await codec.decodeSnapshot(snapshot)
    }
}

struct FailingResolverCodec: OfflineSnapshotCoding {
    let error: any Error & Sendable
    func prepareSnapshot(from item: CLIItem, for request: OfflineSnapshotPreparationIdentity) async throws -> PreparedOfflineSnapshot { throw error }
    func decodeSnapshot(_ snapshot: EncryptedOfflineSnapshot) async throws -> CLIItem { throw error }
}

/// Uses real removal authority at the requested read boundary; never invents an authorization proof.
actor RemovalRaceRepository: OfflineSnapshotPersisting {
    private let base: OfflineSnapshotRepository
    nonisolated var releaseAuthority: OfflineReleaseAuthority { base.releaseAuthority }
    func beginSyncCapture(operation: SyncOperationToken, lifecycleGeneration: UUID) async throws -> OfflineSyncCapture {
        try await base.beginSyncCapture(operation: operation, lifecycleGeneration: lifecycleGeneration)
    }
    func syncWork(capture: OfflineSyncCapture, metadataProofs: [OfflineSnapshotKey: OfflineSyncedMetadataProof],
                  sourceTimes: [String: Date], allowMembershipExpansion: Bool) async throws -> [OfflineSyncWork] {
        try await base.syncWork(capture: capture, metadataProofs: metadataProofs, sourceTimes: sourceTimes,
                                allowMembershipExpansion: allowMembershipExpansion)
    }
    func endSyncCapture(_ capture: OfflineSyncCapture) async throws { try await base.endSyncCapture(capture) }
    func publishSyncBatch(_ publications: [OfflineSyncPublication], capture: OfflineSyncCapture) async throws -> Set<OfflineSnapshotKey> {
        try await base.publishSyncBatch(publications, capture: capture)
    }
    func finishSyncFailures(_ work: [OfflineSyncWork], capture: OfflineSyncCapture) async throws {
        try await base.finishSyncFailures(work, capture: capture)
    }
    private let removeBeforeProof: Bool
    private var removed = false
    private var reads = 0
    init(base: OfflineSnapshotRepository, removeBeforeProof: Bool) {
        self.base = base
        self.removeBeforeProof = removeBeforeProof
    }
    func snapshotReads() -> Int { reads }
    private func removeOnce() async throws {
        if !removed { removed = true; try await base.removeItem("item") }
    }
    func authorizedSnapshot(for key: OfflineSnapshotKey) async throws -> EncryptedOfflineSnapshot? {
        reads += 1
        if !removeBeforeProof { try await removeOnce() }
        return try await base.authorizedSnapshot(for: key)
    }
    func releaseProof(for snapshot: EncryptedOfflineSnapshot) async throws -> OfflineReleaseProof? {
        if removeBeforeProof { try await removeOnce() }
        return try await base.releaseProof(for: snapshot)
    }
    func beginRequest(itemID: String, vaultID: String, shareID: String, kind: OfflineRequestKind,
        expectations: OfflineRequestExpectations) async throws -> OfflineRequestToken? {
        try await base.beginRequest(itemID: itemID, vaultID: vaultID, shareID: shareID, kind: kind,
            expectations: expectations)
    }
    func publish(_ snapshot: PreparedOfflineSnapshot, for request: OfflineRequestToken, refreshedAt: Date) async throws -> Bool { try await base.publish(snapshot, for: request, refreshedAt: refreshedAt) }
    func finishRequest(_ request: OfflineRequestToken, failed: Bool) async throws { try await base.finishRequest(request, failed: failed) }
    func setVaultSelected(_ selected: Bool, vaultID: String) async throws -> OfflineVaultSelection? { try await base.setVaultSelected(selected, vaultID: vaultID) }
    func selectItemManually(itemID: String, vaultID: String, shareID: String) async throws -> UUID { try await base.selectItemManually(itemID: itemID, vaultID: vaultID, shareID: shareID) }
    func keepItemOfflineIndividually(itemID: String, vaultID: String) async throws { try await base.keepItemOfflineIndividually(itemID: itemID, vaultID: vaultID) }
    func itemPolicy(itemID: String, vaultID: String) async throws -> OfflineItemPolicy? { try await base.itemPolicy(itemID: itemID, vaultID: vaultID) }
    func workCandidates(vaultID: String?, includeNewSelections: Bool, refreshExisting: Bool) async throws -> [OfflineSnapshotWorkCandidate] { try await base.workCandidates(vaultID: vaultID, includeNewSelections: includeNewSelections, refreshExisting: refreshExisting) }
    func removeItem(_ itemID: String) async throws { try await base.removeItem(itemID) }
    func purge() async throws { try await base.purge() }
    func recoverAbandonedRequests() async throws { try await base.recoverAbandonedRequests() }
    func hasAuthorizedSnapshot(for key: OfflineSnapshotKey) async throws -> Bool { try await base.hasAuthorizedSnapshot(for: key) }
    func isAuthorized(_ snapshot: EncryptedOfflineSnapshot) async throws -> Bool { try await base.isAuthorized(snapshot) }
    func discardCorruptSnapshot(_ snapshot: EncryptedOfflineSnapshot) async throws { try await base.discardCorruptSnapshot(snapshot) }
    func hasPersistedSnapshots() async throws -> Bool { try await base.hasPersistedSnapshots() }
    func offlineVaultIds() async throws -> Set<String> { try await base.offlineVaultIds() }
    func offlineItemSelection(itemId: String) async throws -> OfflineItemSelection? { try await base.offlineItemSelection(itemId: itemId) }
    func offlineItemSelections() async throws -> [OfflineItemSelection] { try await base.offlineItemSelections() }
}
