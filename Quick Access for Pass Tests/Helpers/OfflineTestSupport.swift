import Foundation
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

    init(itemIDs: [String]) throws {
        database = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
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
    totp: String = ""
) throws -> CLIItem {
    let object: [String: Any] = [
        "id": id,
        "vault_id": vaultID,
        "share_id": shareID,
        "content": [
            "title": "Offline example",
            "note": "",
            // This deliberately differs from the API item ID. Snapshot identity
            // is bound to the API response, not this content field.
            "item_uuid": "content-\(id)",
            "content": [
                "Login": [
                    "username": username,
                    "password": password,
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

/// A finite native command emits test bytes only from its armed TERM trap.
/// Markers and hooks carry lifecycle metadata, never output or process handles.
nonisolated struct NativeTimeoutOverflowFixture: Sendable {
    private struct MarkerSnapshot: Sendable {
        let label: String
        let clock: UInt64
        let readyExists: Bool
        let trapEntryExists: Bool
        let postHeadExists: Bool
    }
    private struct State: Sendable {
        var events: [CLIRunner.LifecycleTesting.Event] = []
        var notificationEntered = false
        var diagnosticPhases: [(CLIRunner.LifecycleTesting.Event, UInt64)] = []
        var diagnosticSnapshots: [MarkerSnapshot] = []
        var droppedDiagnosticPhases = 0
        var droppedDiagnosticSnapshots = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let notificationGate = OfflineTestGate()
    private let readyMarker = FileManager.default.temporaryDirectory.appendingPathComponent("qa-overflow-ready-\(UUID().uuidString)")
    private let termMarker = FileManager.default.temporaryDirectory.appendingPathComponent("qa-overflow-term-\(UUID().uuidString)")
    private let trapEntryMarker = FileManager.default.temporaryDirectory.appendingPathComponent("qa-overflow-entry-\(UUID().uuidString)")
    private let stderr: Bool
    private let delayedNotification: Bool

    init(stderr: Bool = false, delayedNotification: Bool = false) {
        self.stderr = stderr
        self.delayedNotification = delayedNotification
    }

    func run(timeout: TimeInterval, maximumOutputBytes: Int) async throws -> Data {
        // The head child is finite and waited by the shell trap. The shell's
        // otherwise finite builtin loop avoids deferred traps while waiting
        // for sleep or leaving an inherited writer behind.
        let byteCount = stderr ? 256 * 1024 + 4096 : maximumOutputBytes + 4096
        let redirect = stderr ? " >&2" : ""
        let script = "trap 'printf entry > \"\(trapEntryMarker.path)\"; /usr/bin/head -c \(byteCount) /dev/zero\(redirect); printf term > \"\(termMarker.path)\"; exit 0' TERM; " +
            "printf ready > '\(readyMarker.path)'; i=0; while [ $i -lt 10000000 ]; do i=$((i+1)); done"
        let lifecycle = CLIRunner.LifecycleTesting(
            marker: { event in
                let clock = DispatchTime.now().uptimeNanoseconds
                self.state.withLock { state in
                    state.events.append(event)
                    if state.diagnosticPhases.count < 64 {
                        state.diagnosticPhases.append((event, clock))
                    } else {
                        state.droppedDiagnosticPhases += 1
                    }
                }
                if event == .finalizationOwned || event == .completed {
                    self.recordMarkerSnapshot(label: "\(event)")
                }
            },
            suspension: { point in
                guard point == .beforeOutputLimitNotification else { return }
                self.state.withLock { $0.notificationEntered = true }
                if self.delayedNotification { try? await self.notificationGate.wait() }
            }
        )
        let result: Result<Data, any Error>
        do {
            result = .success(try await CLIRunner.run(
                executablePath: "/bin/sh", arguments: ["-c", script], timeout: timeout,
                maximumOutputBytes: maximumOutputBytes, lifecycleTesting: lifecycle
            ))
        } catch {
            result = .failure(error)
        }
        recordMarkerSnapshot(label: "callerResult")
        // Always release and join the existing notification task, including
        // expected RED errors or caller cancellation. A missing notification
        // is bounded failed evidence, not an unbounded test wait.
        let notificationJoin = Task {
            await notificationGate.open()
            for _ in 0..<100 {
                if state.withLock({ $0.events.contains(.outputLimitNotificationCompleted) }) { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        await notificationJoin.value
        recordMarkerSnapshot(label: "notificationJoined")
        #expect(state.withLock { $0.notificationEntered })
        #expect(state.withLock { $0.events.filter { $0 == .outputLimitNotificationCompleted }.count } == 1)
        return try result.get()
    }

    func expectTimeoutTrapAndSingleCompletion() {
        defer { reportDiagnosticMetadata() }
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

    private func recordMarkerSnapshot(label: String) {
        // Filesystem observations stay outside the metadata lock. They are
        // host observation times, not native child exit or write timestamps.
        let snapshot = MarkerSnapshot(
            label: label, clock: DispatchTime.now().uptimeNanoseconds,
            readyExists: FileManager.default.fileExists(atPath: readyMarker.path),
            trapEntryExists: FileManager.default.fileExists(atPath: trapEntryMarker.path),
            postHeadExists: FileManager.default.fileExists(atPath: termMarker.path)
        )
        state.withLock { state in
            if state.diagnosticSnapshots.count < 8 {
                state.diagnosticSnapshots.append(snapshot)
            } else {
                state.droppedDiagnosticSnapshots += 1
            }
        }
    }

    private func reportDiagnosticMetadata() {
        recordMarkerSnapshot(label: "assertionsFinished")
        let snapshot = state.withLock {
            ($0.diagnosticPhases, $0.diagnosticSnapshots,
             $0.droppedDiagnosticPhases, $0.droppedDiagnosticSnapshots)
        }
        let phases = snapshot.0.map { "\($0.0)@\($0.1)" }.joined(separator: ",")
        let markers = snapshot.1.map {
            "\($0.label)@\($0.clock):ready=\($0.readyExists):trapEntry=\($0.trapEntryExists):postHead=\($0.postHeadExists)"
        }.joined(separator: ",")
        print("CLIRunner timeout-overflow metadata [stderr=\(stderr),delayed=\(delayedNotification)]: " +
              "phases=\(phases); markers=\(markers); droppedPhases=\(snapshot.2); droppedSnapshots=\(snapshot.3)")
    }

    func removeMarkers() {
        try? FileManager.default.removeItem(at: readyMarker)
        try? FileManager.default.removeItem(at: termMarker)
        try? FileManager.default.removeItem(at: trapEntryMarker)
    }
}

nonisolated struct NativeTimeoutOverflowRunner: CLIRunning {
    let fixture: NativeTimeoutOverflowFixture
    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        try await run(executablePath: executablePath, arguments: arguments, timeout: timeout, maximumOutputBytes: 4 * 1024 * 1024 + 4096)
    }
    func run(executablePath: String, arguments: [String], timeout: TimeInterval, maximumOutputBytes: Int) async throws -> Data {
        try await fixture.run(timeout: timeout, maximumOutputBytes: maximumOutputBytes)
    }
}
