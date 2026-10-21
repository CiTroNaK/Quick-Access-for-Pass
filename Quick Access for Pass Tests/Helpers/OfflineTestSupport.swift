import Darwin
import Foundation

extension SecretItemResolving {
    func resolveAutoFillValue(itemId: String, vaultId: String, shareId: String, kind: AutoFillValueKind, context: SecretResolutionContext) async throws -> ResolvedSecret<String> {
        throw OfflineSecretResolver.Error.unavailable
    }
}
import GRDB
import os
import Testing
@testable import Quick_Access_for_Pass

/// Exact persisted metadata/ciphertext capture for non-destructive lifecycle regressions.
nonisolated struct OfflinePersistedTestState: Equatable, Sendable {
    let schemaVersion: Int
    let revision: String
    let fingerprint: Data
    let payload: Data
    let selection: OfflineItemSelection
    let pendingRequestID: String?

    static func capture(database: DatabaseManager, itemID: String) async throws -> Self? {
        try await database.reader.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT s.*, o.pendingRequestId FROM offlineSnapshots s
                JOIN offlineItems o ON o.itemId = s.itemId AND o.vaultId = s.vaultId
                WHERE s.itemId = ?
                """, arguments: [itemID]),
                  let selection = try OfflineItemSelection.fetchOne(db, key: itemID) else { return nil }
            return Self(
                schemaVersion: row["schemaVersion"], revision: row["snapshotRevision"],
                fingerprint: row["keyFingerprint"], payload: row["encryptedPayload"],
                selection: selection, pendingRequestID: row["pendingRequestId"]
            )
        }
    }
}

/// Shared cancellable gate for lifecycle races. Every continuation is removed
/// before it is resumed, including cancellation racing registration.
actor OfflineTestGate {
    private var isOpen = false
    private var entered = false
    private var waiters: [UUID: CheckedContinuation<Void, any Swift.Error>] = [:]
    private var entryWaiters: [UUID: CheckedContinuation<Void, any Swift.Error>] = [:]

    func wait() async throws {
        entered = true
        resumeAll(&entryWaiters)
        guard !isOpen else { return }
        try await suspend(.open)
    }

    func waitUntilEntered() async throws {
        guard !entered else { return }
        try await suspend(.entry)
    }

    func open() {
        isOpen = true
        resumeAll(&waiters)
    }

    nonisolated private enum WaitKind: Sendable { case open, entry }

    private func suspend(_ kind: WaitKind) async throws {
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Swift.Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if kind == .open {
                    waiters[id] = continuation
                } else {
                    entryWaiters[id] = continuation
                }
            }
        }, onCancel: {
            Task { await self.cancel(id) }
        })
    }

    private func cancel(_ id: UUID) {
        if let continuation = waiters.removeValue(forKey: id) ?? entryWaiters.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        }
    }

    private func resumeAll(_ continuations: inout [UUID: CheckedContinuation<Void, any Swift.Error>]) {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending.values {
            continuation.resume()
        }
    }
}

actor OfflineFixtureViewer: OfflineItemViewing {
    private let beforeView: @Sendable () async throws -> Void
    private var calls: [String: Int] = [:]
    private let beforeViewItem: @Sendable (String) async throws -> Void

    func callCount(itemID: String) -> Int { calls[itemID, default: 0] }

    init(beforeView: @escaping @Sendable () async throws -> Void = {},
         beforeViewItem: @escaping @Sendable (String) async throws -> Void = { _ in }) {
        self.beforeView = beforeView
        self.beforeViewItem = beforeViewItem
    }

    func viewItem(itemId: String, shareId: String) async throws -> CLIItem {
        calls[itemId, default: 0] += 1
        try await beforeView()
        try await beforeViewItem(itemId)
        return try offlineTestCLIItem(
            id: itemId, vaultID: "vault", shareID: shareId,
            password: "fake-password", username: "user@example.com"
        )
    }
}

actor OfflineFixtureKeys: OfflineSnapshotKeyProviding {
    private var material: Data?
    private var creates = 0
    private var existingLookups = 0

    init(initialMaterial: Data? = Data(repeating: 7, count: 32)) {
        material = initialMaterial
    }

    func existingSnapshotKey() -> Data? {
        existingLookups += 1
        return material
    }

    func createSnapshotKey() -> Data {
        creates += 1
        if let material { return material }
        let created = Data(repeating: 7, count: 32) // Test material, never production RNG.
        material = created
        return created
    }

    func createCount() -> Int { creates }
    func existingLookupCount() -> Int { existingLookups }
}

struct OfflineLifecycleFixture {
    let database: DatabaseManager
    let repository: OfflineSnapshotRepository
    let items: [PassItem]

    init(itemIDs: [String], offlineMutationTesting: OfflineMutationTesting? = nil) throws {
        database = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8), offlineMutationTesting: offlineMutationTesting)
        items = itemIDs.map { offlineTestMetadata(id: $0, vaultID: "vault") }
        try database.upsertVaults([PassVault(id: "vault", name: "Vault", shareId: "share")])
        try database.upsertItems(items)
        repository = OfflineSnapshotRepository(database: database)
    }

    func codec(keys: any OfflineSnapshotKeyProviding = OfflineFixtureKeys()) -> OfflineSnapshotCodec {
        OfflineSnapshotCodec(
            keyMaterialProvider: keys,
            hasPersistedSnapshots: { try await repository.hasPersistedSnapshots() }
        )
    }

    func service(viewer: any OfflineItemViewing = OfflineFixtureViewer()) -> OfflineModeService {
        OfflineModeService(repository: repository, codec: codec(), cliService: viewer)
    }
}

/// Explicit observation events keep fixture admission separate from production readiness.
let offlineFixtureObservationGeneration = UUID()

func initializeOfflineFixtureService(_ service: OfflineModeService) async throws {
    try await service.initialize()
    await service.updateSelectionObservation(generation: offlineFixtureObservationGeneration, status: .starting)
    await service.updateSelectionObservation(generation: offlineFixtureObservationGeneration, status: .fresh)
}

func offlineTestMetadata(
    id: String,
    vaultID: String,
    modifyTime: Date = Date(timeIntervalSince1970: 2)
) -> PassItem {
    PassItem(
        id: id,
        vaultId: vaultID,
        title: "Offline example",
        itemType: .login,
        subtitle: "person@example.test",
        url: nil,
        hasTOTP: false,
        state: "Active",
        createTime: Date(timeIntervalSince1970: 1),
        modifyTime: modifyTime,
        useCount: 0,
        lastUsedAt: nil
    )
}

func offlineTestCLIItem(
    id: String,
    vaultID: String,
    shareID: String,
    password: String,
    username: String = "person@example.test",
    totp: String = "",
    email: String = "",
    note: String = ""
) throws -> CLIItem {
    let object: [String: Any] = [
        "id": id,
        "vault_id": vaultID,
        "share_id": shareID,
        "content": [
            "title": "Offline example",
            "note": note,
            // This deliberately differs from the API item ID. Snapshot identity
            // is bound to the API response, not this content field.
            "item_uuid": "content-\(id)",
            "content": [
                "Login": [
                    "username": username,
                    "password": password,
                    "email": email,
                    "totp_uri": totp,
                    "urls": []
                ]
            ]
        ],
        "state": "Active",
        "flags": [],
        "create_time": "",
        "modify_time": ""
    ]
    return try JSONDecoder().decode(
        CLIItem.self,
        from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    )
}

/// A finite native command exceeds its output limit only from its armed TERM trap.
/// Markers and hooks carry lifecycle metadata, never output or process handles.
nonisolated struct NativeTimeoutOverflowFixture: Sendable {
    private struct State: Sendable {
        var incomingDeadlines: [CLIExecutionDeadline] = []
        var forwardedDeadlines: [CLIExecutionDeadline] = []
        var events: [CLIRunner.LifecycleTesting.Event] = []
        var notificationEntered = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let notificationGate = OfflineTestGate()
    private let readyMarker = FileManager.default.temporaryDirectory.appendingPathComponent("qa-overflow-ready-\(UUID().uuidString)")
    private let termMarker = FileManager.default.temporaryDirectory.appendingPathComponent("qa-overflow-term-\(UUID().uuidString)")
    private let waitFIFO = FileManager.default.temporaryDirectory.appendingPathComponent("qa-overflow-wait-\(UUID().uuidString)")
    private let stderr: Bool
    private let delayedNotification: Bool

    private enum Budget: Sendable { case relative(TimeInterval), absolute(CLIExecutionDeadline) }

    init(stderr: Bool = false, delayedNotification: Bool = false) {
        self.stderr = stderr
        self.delayedNotification = delayedNotification
    }

    func observedDeadlines() -> (incoming: [CLIExecutionDeadline], forwarded: [CLIExecutionDeadline]) {
        state.withLock { ($0.incomingDeadlines, $0.forwardedDeadlines) }
    }

    func run(timeout: TimeInterval, maximumOutputBytes: Int) async throws -> Data {
        try await run(budget: .relative(timeout), maximumOutputBytes: maximumOutputBytes)
    }

    func run(deadline: CLIExecutionDeadline, maximumOutputBytes: Int) async throws -> Data {
        state.withLock { $0.incomingDeadlines.append(deadline) }
        return try await run(budget: .absolute(deadline), maximumOutputBytes: maximumOutputBytes)
    }

    private func run(budget: Budget, maximumOutputBytes: Int) async throws -> Data {
        // A timed builtin read blocks without consuming a CPU core or leaving
        // an inherited writer. TERM interrupts the read, and builtin printf
        // emits the overflow without launching a child inside the 250 ms grace.
        guard mkfifo(waitFIFO.path, mode_t(0o600)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // Fill exactly to the accepted cap before readiness. Only the small
        // TERM burst crosses it; a 256 KiB stderr transfer must not depend on
        // fitting entirely inside the original 250 ms termination grace.
        let limit = stderr ? 256 * 1024 : maximumOutputBytes
        let redirect = stderr ? " >&2" : ""
        let remainder = String(repeating: "x", count: limit % 1024)
        let script = "payload='\(String(repeating: "x", count: 1024))'; " +
            "trap 'i=0; while [ $i -lt 5 ]; do printf %s \"$payload\"\(redirect); i=$((i+1)); done; " +
            "printf term > \"\(termMarker.path)\"; exit 0' TERM; " +
            "exec 3<> '\(waitFIFO.path)'; i=0; while [ $i -lt \(limit / 1024) ]; " +
            "do printf %s \"$payload\"\(redirect); i=$((i+1)); done; printf %s '\(remainder)'\(redirect); " +
            "printf ready > '\(readyMarker.path)'; read -r -t 8 unused <&3; exit 93"
        let lifecycle = CLIRunner.LifecycleTesting(
            marker: { event in self.state.withLock { $0.events.append(event) } },
            suspension: { point in
                guard point == .beforeOutputLimitNotification else { return }
                self.state.withLock { $0.notificationEntered = true }
                if self.delayedNotification { try? await self.notificationGate.wait() }
            }
        )
        // Propagate the native result before observing diagnostics: an outer
        // resolver still has to check this operation's original deadline.
        switch budget {
        case .relative(let timeout):
            return try await CLIRunner.run(
                executablePath: "/bin/sh", arguments: ["-c", script], timeout: timeout,
                maximumOutputBytes: maximumOutputBytes, lifecycleTesting: lifecycle
            )
        case .absolute(let deadline):
            state.withLock { $0.forwardedDeadlines.append(deadline) }
            return try await CLIRunner.run(
                executablePath: "/bin/sh", arguments: ["-c", script], deadline: deadline,
                maximumOutputBytes: maximumOutputBytes, lifecycleTesting: lifecycle
            )
        }
    }

    var completedOutputLimitNotifications: Int {
        state.withLock { $0.events.filter { $0 == .outputLimitNotificationCompleted }.count }
    }

    func expectTimeoutTrapAndSingleCompletion() async {
        // Diagnostic settlement belongs after the deadline-bound caller has
        // received the native error, not on the fixture runner's result path.
        await notificationGate.open()
        for _ in 0..<100 {
            if completedOutputLimitNotifications == 1 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(state.withLock { $0.notificationEntered })
        #expect(completedOutputLimitNotifications == 1)
        #expect(FileManager.default.fileExists(atPath: readyMarker.path))
        #expect(FileManager.default.fileExists(atPath: termMarker.path))
        let events = state.withLock { $0.events }
        #expect(events.filter { $0 == .terminating }.count == 1)
        #expect(events.filter { $0 == .finalizationOwned }.count == 1)
        #expect(events.filter { $0 == .completed }.count == 1)
        if delayedNotification {
            let completion = events.firstIndex { $0 == .completed }
            let notification = events.firstIndex { $0 == .outputLimitNotificationCompleted }
            #expect(completion != nil && notification != nil)
            if let completion, let notification { #expect(completion < notification) }
        }
    }

    func removeMarkers() {
        try? FileManager.default.removeItem(at: readyMarker)
        try? FileManager.default.removeItem(at: termMarker)
        try? FileManager.default.removeItem(at: waitFIFO)
    }
}

nonisolated struct NativeTimeoutOverflowRunner: CLIRunning {
    func run(executablePath: String, arguments: [String], deadline: CLIExecutionDeadline, maximumOutputBytes: Int) async throws -> Data {
        try await fixture.run(deadline: deadline, maximumOutputBytes: maximumOutputBytes)
    }
    let fixture: NativeTimeoutOverflowFixture
    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        try await run(executablePath: executablePath, arguments: arguments, timeout: timeout, maximumOutputBytes: 4 * 1024 * 1024 + 4096)
    }
    func run(executablePath: String, arguments: [String], timeout: TimeInterval, maximumOutputBytes: Int) async throws -> Data {
        try await fixture.run(timeout: timeout, maximumOutputBytes: maximumOutputBytes)
    }
}
