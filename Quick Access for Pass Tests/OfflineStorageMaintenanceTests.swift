import Foundation
import GRDB
import Synchronization
import Testing
@testable import Quick_Access_for_Pass

@Suite("Offline storage maintenance", .timeLimit(.minutes(1)))
struct OfflineStorageMaintenanceTests {
    @Test func startupRetriesBusyCheckpointAtMostThreeTimes() async throws {
        let checkpointer = ScriptedOfflineCheckpointer(results: [.busy, .busy, .complete])
        let maintenance = OfflineStorageMaintenance(checkpointer: checkpointer, retryDelay: {})

        await maintenance.checkpointAtStartup()

        #expect(await checkpointer.attemptCount() == 3)
    }

    @Test func startupStopsAfterThreeBusyCheckpoints() async throws {
        let checkpointer = ScriptedOfflineCheckpointer(results: [.busy])
        let maintenance = OfflineStorageMaintenance(checkpointer: checkpointer, retryDelay: {})

        await maintenance.checkpointAtStartup()

        #expect(await checkpointer.attemptCount() == 3)
    }

    @Test func checkpointErrorDoesNotRetryOrBecomeLogicalDeletionFailure() async throws {
        let checkpointer = ScriptedOfflineCheckpointer(results: [.failure])
        let maintenance = OfflineStorageMaintenance(checkpointer: checkpointer, retryDelay: {})

        await maintenance.checkpointAtStartup()

        #expect(await checkpointer.attemptCount() == 1)
    }

    @Test func concurrentRequestsCoalesceIntoOneOwnedBatch() async throws {
        let gate = OfflineTestGate()
        let checkpointer = ScriptedOfflineCheckpointer(results: [.complete], beforeCheckpoint: { try await gate.wait() })
        let maintenance = OfflineStorageMaintenance(checkpointer: checkpointer, retryDelay: {})

        await maintenance.requestCheckpoint()
        try await gate.waitUntilEntered()
        await maintenance.requestCheckpoint()
        await maintenance.requestCheckpoint()
        await gate.open()
        await maintenance.stop()

        #expect(await checkpointer.attemptCount() == 1)
    }

    @Test func stopCancelsAndAwaitsTheOnlyWorkerAndPreventsResurrection() async throws {
        let gate = OfflineTestGate()
        let checkpointer = ScriptedOfflineCheckpointer(results: [.complete], beforeCheckpoint: { try await gate.wait() })
        let maintenance = OfflineStorageMaintenance(checkpointer: checkpointer, retryDelay: {})

        await maintenance.requestCheckpoint()
        try await gate.waitUntilEntered()
        await maintenance.stop()
        await maintenance.requestCheckpoint()

        #expect(await checkpointer.attemptCount() == 1)
    }

    @Test func temporarySQLCipherPoolCheckpointCompletesOutsideTransactions() async throws {
        let fixture = try TemporaryCheckpointPool()
        defer { fixture.remove() }
        let checkpointer = DatabaseWALCheckpointer(writer: fixture.pool)

        #expect(try await checkpointer.checkpoint() == .complete)
    }

    @Test func heldSQLCipherReaderMakesTruncateBusyUntilReleased() async throws {
        let fixture = try TemporaryCheckpointPool()
        defer { fixture.remove() }
        let reader = HeldCheckpointReader(pool: fixture.pool)
        reader.start()
        do {
            try await reader.waitUntilReading()
            #expect(fixture.hasWALFrames)

            let checkpointer = DatabaseWALCheckpointer(writer: fixture.pool)
            #expect(try await checkpointer.checkpoint() == .busy)

            reader.release()
            try await reader.waitUntilFinished()
            #expect(try await checkpointer.checkpoint() == .complete)
        } catch {
            reader.release()
            _ = try? await reader.waitUntilFinished()
            throw error
        }
    }

    @Test func purgingSnapshotsRetainsOperationScopedKeyMaterial() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let item = try #require(fixture.items.first)
        let keys = OfflineFixtureKeys()
        let service = OfflineModeService(
            repository: fixture.repository,
            codec: fixture.codec(keys: keys),
            cliService: OfflineFixtureViewer()
        )
        try await initializeOfflineFixtureService(service)
        try await service.makeAvailableOffline(item: item, shareId: "share")
        let keyLookupsBeforePurge = await keys.existingLookupCount()
        let keyCreatesBeforePurge = await keys.createCount()

        try await service.removeAllOfflineData()

        #expect(try await fixture.repository.hasPersistedSnapshots() == false)
        #expect(await keys.existingLookupCount() == keyLookupsBeforePurge)
        #expect(await keys.createCount() == keyCreatesBeforePurge)
    }

    @Test func committedRepositoryDeletionPathsRequestMaintenanceButRollbackDoesNot() async throws {
        let fixture = try await MaintenanceRepositoryFixture()

        let itemRequest = try #require(try await fixture.repository.beginRequest(
            itemID: "item", vaultID: "vault", shareID: "share", kind: .selection
        ))
        try await fixture.repository.removeItem("item")
        await fixture.checkpointer.waitForAttempt(1)
        #expect(try await fixture.repository.offlineItemSelection(itemId: "item") == nil)

        let vaultRequest = try #require(try await fixture.repository.beginRequest(
            itemID: "item", vaultID: "vault", shareID: "share", kind: .selection
        ))
        _ = vaultRequest
        _ = try await fixture.repository.setVaultSelected(false, vaultID: "vault")
        await fixture.checkpointer.waitForAttempt(2)
        #expect(try await fixture.repository.offlineVaultIds().isEmpty)

        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        let purgeRequest = try #require(try await fixture.repository.beginRequest(
            itemID: "item", vaultID: "vault", shareID: "share", kind: .selection
        ))
        _ = purgeRequest
        try await fixture.repository.purge()
        await fixture.checkpointer.waitForAttempt(3)
        #expect(try await fixture.repository.offlineItemSelections().isEmpty)

        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        let corruptRequest = try #require(try await fixture.repository.beginRequest(
            itemID: "item", vaultID: "vault", shareID: "share", kind: .selection
        ))
        let corrupt = fixture.snapshot(for: corruptRequest)
        #expect(try await fixture.repository.publish(corrupt, for: corruptRequest, refreshedAt: .now))
        try await fixture.repository.discardCorruptSnapshot(corrupt)
        await fixture.checkpointer.waitForAttempt(4)
        #expect(try await fixture.repository.hasPersistedSnapshots() == false)

        let rollbackRequest = try #require(try await fixture.repository.beginRequest(
            itemID: "item", vaultID: "vault", shareID: "share", kind: .selection
        ))
        _ = rollbackRequest
        try await fixture.database.writer.write { db in
            try db.execute(sql: """
            CREATE TRIGGER rejectOfflineDeletion BEFORE DELETE ON offlineItems
            BEGIN SELECT RAISE(ABORT, 'test'); END
            """)
        }
        await #expect(throws: OfflinePersistenceError.persistenceFailed) {
            try await fixture.repository.removeItem("item")
        }
        #expect(await fixture.checkpointer.attemptCount() == 4)
        try await fixture.database.writer.write { db in
            try db.execute(sql: "DROP TRIGGER rejectOfflineDeletion")
        }
        await fixture.maintenance.stop()
    }

    @Test(arguments: [false, true])
    func committedPopulatedPurgeRemainsDeletedWhenCheckpointIsBusyOrThrows(throwsError: Bool) async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let keys = OfflineFixtureKeys()
        let gate = OfflineTestGate()
        let finished = OfflineTestGate()
        let checkpointer = DeletionOutcomeCheckpointer(throwsError: throwsError, gate: gate, finished: finished)
        let maintenance = OfflineStorageMaintenance(checkpointer: checkpointer, retryDelay: {})
        let repository = OfflineSnapshotRepository(database: fixture.database, maintenance: maintenance)
        let service = OfflineModeService(repository: repository, codec: fixture.codec(keys: keys), cliService: OfflineFixtureViewer())
        do {
            try await initializeOfflineFixtureService(service)
            try await service.makeAvailableOffline(item: #require(fixture.items.first), shareId: "share")
            #expect(try await repository.hasPersistedSnapshots())
            let keyLookups = await keys.existingLookupCount()
            let keyCreates = await keys.createCount()

            // Purge returns its committed logical outcome while maintenance is
            // still blocked. Neither later busy nor error can change that outcome.
            try await service.removeAllOfflineData()
            try await gate.waitUntilEntered()
            #expect(try await repository.offlineItemSelections().isEmpty)
            #expect(try await repository.offlineVaultIds().isEmpty)
            #expect(try await repository.hasPersistedSnapshots() == false)
            await gate.open()
            try await finished.wait()
            await maintenance.stop()

            #expect(await checkpointer.attemptCount() == (throwsError ? 1 : 3))
            #expect(try await repository.hasPersistedSnapshots() == false)
            #expect(await keys.existingLookupCount() == keyLookups)
            #expect(await keys.createCount() == keyCreates)
        } catch {
            await gate.open()
            await maintenance.stop()
            throw error
        }
    }

    @Test func startupCheckpointFollowsCommittedSelectionRecoveryAndCancelledWaiterJoins() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        _ = try #require(try await fixture.repository.beginRequest(
            itemID: "item", vaultID: "vault", shareID: "share", kind: .selection
        ))
        let gate = OfflineTestGate()
        let checkpointer = ScriptedOfflineCheckpointer(results: [.complete], beforeCheckpoint: {
            let recovered = try #require(try await fixture.repository.offlineItemSelection(itemId: "item"))
            #expect(recovered.isManuallySelected)
            #expect(recovered.cacheStatus == .unavailable)
            #expect(recovered.lastRefreshedAt == nil)
            let pendingID = try await fixture.database.reader.read { db in
                try String.fetchOne(db, sql: "SELECT pendingRequestId FROM offlineItems WHERE itemId = 'item'")
            }
            #expect(pendingID == nil)
            try await gate.wait()
        })
        let maintenance = OfflineStorageMaintenance(checkpointer: checkpointer, retryDelay: {})
        let service = OfflineModeService(
            repository: fixture.repository, codec: fixture.codec(), cliService: OfflineFixtureViewer(),
            maintenance: maintenance
        )
        let initialization = Task { try await service.initialize() }
        do {
            try await gate.waitUntilEntered()
            #expect(await service.isReady() == false)
            initialization.cancel()
            await gate.open()
            try await initialization.value
            #expect(await service.isReady())
            await maintenance.stop()
        } catch {
            initialization.cancel()
            await gate.open()
            _ = try? await initialization.value
            await maintenance.stop()
            throw error
        }
    }

    @Test func laterExplicitRequestStartsNewBatchButTerminalStopRejectsIt() async {
        let checkpointer = RecordingOfflineCheckpointer()
        let maintenance = OfflineStorageMaintenance(checkpointer: checkpointer, retryDelay: {})
        await maintenance.checkpointAtStartup()
        #expect(await checkpointer.attemptCount() == 1)
        await maintenance.requestCheckpoint()
        await checkpointer.waitForAttempt(2)
        await maintenance.stop()
        await maintenance.requestCheckpoint()
        await maintenance.checkpointAtStartup()
        #expect(await checkpointer.attemptCount() == 2)
    }

    @Test func memorySQLCipherWriterCheckpointIsBenignWithoutWAL() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("memory-checkpoint".utf8))
        #expect(try await DatabaseWALCheckpointer(writer: database.writer).checkpoint() == .complete)
    }

    @Test func checkpointResultParserRequiresAllThreeValidColumns() throws {
        #expect(try DatabaseWALCheckpointer.interpret(busy: 0, log: 4, checkpointed: 4) == .complete)
        #expect(try DatabaseWALCheckpointer.interpret(busy: 1, log: 4, checkpointed: 0) == .busy)
        #expect(try DatabaseWALCheckpointer.interpret(busy: 0, log: -1, checkpointed: -1) == .complete)

        #expect(throws: DatabaseWALCheckpointer.Error.malformedResult) {
            try DatabaseWALCheckpointer.interpret(busy: nil, log: 0, checkpointed: 0)
        }
        #expect(throws: DatabaseWALCheckpointer.Error.malformedResult) {
            try DatabaseWALCheckpointer.interpret(busy: 0, log: -1, checkpointed: 0)
        }
        #expect(throws: DatabaseWALCheckpointer.Error.malformedResult) {
            try DatabaseWALCheckpointer.interpret(busy: 2, log: 0, checkpointed: 0)
        }
        #expect(throws: DatabaseWALCheckpointer.Error.malformedResult) {
            try DatabaseWALCheckpointer.interpret(busy: 0, log: 4, checkpointed: 3)
        }
    }
}

private struct MaintenanceRepositoryFixture {
    let database: DatabaseManager
    let checkpointer: RecordingOfflineCheckpointer
    let maintenance: OfflineStorageMaintenance
    let repository: OfflineSnapshotRepository

    init() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("maintenance-fixture".utf8))
        try database.upsertVaults([PassVault(id: "vault", name: "Vault", shareId: "share")])
        try database.upsertItems([offlineTestMetadata(id: "item", vaultID: "vault")])
        let checkpointer = RecordingOfflineCheckpointer()
        let maintenance = OfflineStorageMaintenance(checkpointer: checkpointer, retryDelay: {})
        let repository = OfflineSnapshotRepository(database: database, maintenance: maintenance)
        // Enablement itself does not delete data and must not request a checkpoint.
        _ = try await repository.setVaultSelected(true, vaultID: "vault")
        self.database = database
        self.checkpointer = checkpointer
        self.maintenance = maintenance
        self.repository = repository
    }

    func snapshot(for request: OfflineRequestToken) -> EncryptedOfflineSnapshot {
        EncryptedOfflineSnapshot(
            identity: OfflineSnapshotIdentity(
                key: request.key,
                revision: UUID(),
                keyFingerprint: Data(repeating: 7, count: 32)
            ),
            payload: Data(repeating: 1, count: 28)
        )
    }
}

private actor RecordingOfflineCheckpointer: OfflineCheckpointing {
    private var attempts = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func checkpoint() async throws -> OfflineCheckpointResult {
        attempts += 1
        let ready = waiters.filter { attempts >= $0.0 }
        waiters.removeAll { attempts >= $0.0 }
        for (_, continuation) in ready { continuation.resume() }
        return .complete
    }

    func waitForAttempt(_ expected: Int) async {
        guard attempts < expected else { return }
        await withCheckedContinuation { waiters.append((expected, $0)) }
    }

    func attemptCount() -> Int { attempts }
}

private actor DeletionOutcomeCheckpointer: OfflineCheckpointing {
    private let throwsError: Bool
    private let gate: OfflineTestGate
    private let finished: OfflineTestGate
    private var attempts = 0

    init(throwsError: Bool, gate: OfflineTestGate, finished: OfflineTestGate) {
        self.throwsError = throwsError
        self.gate = gate
        self.finished = finished
    }

    func checkpoint() async throws -> OfflineCheckpointResult {
        attempts += 1
        try await gate.wait()
        if throwsError || attempts == 3 { await finished.open() }
        if throwsError { throw ScriptedCheckpointError.failed }
        return .busy
    }

    func attemptCount() -> Int { attempts }
}

private enum ScriptedCheckpointStep: Sendable {
    case complete
    case busy
    case failure
}

private enum ScriptedCheckpointError: Error, Sendable {
    case failed
}

private actor ScriptedOfflineCheckpointer: OfflineCheckpointing {
    private let results: [ScriptedCheckpointStep]
    private let beforeCheckpoint: @Sendable () async throws -> Void
    private var attempts = 0

    init(
        results: [ScriptedCheckpointStep],
        beforeCheckpoint: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.results = results
        self.beforeCheckpoint = beforeCheckpoint
    }

    func checkpoint() async throws -> OfflineCheckpointResult {
        attempts += 1
        try await beforeCheckpoint()
        let index = min(attempts - 1, max(0, results.count - 1))
        switch results.isEmpty ? ScriptedCheckpointStep.complete : results[index] {
        case .complete: return .complete
        case .busy: return .busy
        case .failure: throw ScriptedCheckpointError.failed
        }
    }

    func attemptCount() -> Int { attempts }
}

/// Holds an actual DatabasePool read transaction on its own test queue.
/// Production maintenance owns neither this synchronization nor this reader.
private final class HeldCheckpointReader: Sendable {
    private struct State: Sendable {
        var didEnterRead = false
        var failed = false
    }

    private enum Error: Swift.Error {
        case didNotEnterRead
        case timedOut
    }

    private let pool: DatabasePool
    private let readerQueue = DispatchQueue(label: "OfflineStorageMaintenanceTests.held-reader")
    private let waiterQueue = DispatchQueue(label: "OfflineStorageMaintenanceTests.held-reader-waiter")
    private let entered = DispatchSemaphore(value: 0)
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let state = Mutex(State())

    init(pool: DatabasePool) {
        self.pool = pool
    }

    func start() {
        readerQueue.async { [self] in
            defer { finished.signal() }
            do {
                try pool.read { db in
                    _ = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM checkpointTest")
                    state.withLock { $0.didEnterRead = true }
                    entered.signal()
                    guard releaseSemaphore.wait(timeout: .now() + 5) == .success else {
                        state.withLock { $0.failed = true }
                        return
                    }
                }
            } catch {
                state.withLock { $0.failed = true }
                entered.signal()
            }
        }
    }

    func waitUntilReading() async throws {
        guard await wait(for: entered) else { throw Error.timedOut }
        guard state.withLock({ $0.didEnterRead && !$0.failed }) else {
            throw Error.didNotEnterRead
        }
    }

    func release() {
        releaseSemaphore.signal()
    }

    func waitUntilFinished() async throws {
        guard await wait(for: finished) else { throw Error.timedOut }
    }

    private func wait(for semaphore: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            waiterQueue.async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 5) == .success)
            }
        }
    }
}

private final class TemporaryCheckpointPool: Sendable {
    let root: URL
    let databaseURL: URL
    let pool: DatabasePool

    var hasWALFrames: Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: databaseURL.path + "-wal"),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.intValue > 0
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var configuration = Configuration()
        let passphrase = Data("offline-maintenance-test".utf8)
        configuration.prepareDatabase { db in
            try EncryptedDatabaseConfiguration.prepare(db, passphrase: passphrase)
        }
        databaseURL = root.appendingPathComponent("maintenance.db")
        pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        try pool.write { db in
            _ = try String.fetchOne(db, sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "CREATE TABLE checkpointTest (value TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO checkpointTest (value) VALUES ('metadata')")
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
