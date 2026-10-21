import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("AppDelegate offline lifecycle", .timeLimit(.minutes(1)))
@MainActor
struct AppDelegateOfflineLifecycleTests {
    @Test func successfulPassCLILogoutPurgesUnifiedOfflineData() async throws {
        let fixture = try await makeFixture(logoutError: nil)
        try await AppDelegate.logoutFromPassCLI(cliService: fixture.cliService, offlineModeService: fixture.service)
        #expect(try await fixture.repository.hasPersistedSnapshots() == false)
        #expect(try await fixture.repository.offlineItemSelections().isEmpty)
        #expect(try await fixture.repository.offlineVaultIds().isEmpty)
        #expect(try await exclusionCount(fixture.database) == 0)
    }

    @Test func failedPassCLILogoutRetainsUnifiedOfflineData() async throws {
        let fixture = try await makeFixture(logoutError: .commandFailed("logout failed"))
        await #expect(throws: CLIError.self) {
            try await AppDelegate.logoutFromPassCLI(cliService: fixture.cliService, offlineModeService: fixture.service)
        }
        #expect(try await fixture.repository.hasPersistedSnapshots())
        #expect(try await fixture.repository.offlineItemSelections().count == 1)
        #expect(try await fixture.repository.offlineVaultIds() == ["vault"])
        #expect(try await exclusionCount(fixture.database) == 1)
    }

    @Test func successfulLogoutWaitsForPreparationJoinBeforePurgingExclusions() async throws {
        let base = try OfflineLifecycleFixture(itemIDs: ["blocked", "excluded"])
        _ = try await base.repository.setVaultSelected(true, vaultID: "vault")
        try await base.repository.removeItem("excluded")
        let gate = OfflineLogoutPreparationGate()
        let viewer = OfflineFixtureViewer(beforeView: { await gate.wait() })
        let service = OfflineModeService(repository: base.repository, codec: base.codec(), cliService: viewer)
        try await initializeOfflineFixtureService(service)
        try await service.selectWholeVault(true, vaultID: "vault")
        await gate.waitUntilEntered()
        let completion = OfflineLogoutCompletion()
        let cliService = PassCLIService(cliPath: "/usr/bin/pass", runner: OfflineLogoutRunner(error: nil))
        let logout = Task {
            try await AppDelegate.logoutFromPassCLI(cliService: cliService, offlineModeService: service)
            await completion.markCompleted()
        }

        #expect(await waitUntil { (try? await base.repository.offlineVaultIds().isEmpty) == true })
        #expect(await completion.isCompleted() == false)
        await gate.open()
        try await logout.value
        #expect(await completion.isCompleted())
        await service.waitUntilIdle()
        #expect(try await base.repository.offlineItemSelections().isEmpty)
        #expect(try await exclusionCount(base.database) == 0)
        #expect(try await base.repository.hasPersistedSnapshots() == false)
        await service.stop()
    }

    @Test func appDelegateRevokesSharedDeliveryBeforeLogoutCanAwait() async throws {
        let fixture = try await makeFixture(logoutError: nil)
        let gate = OfflineTestGate()
        let delegate = AppDelegate()
        let token = delegate.secretReleaseGuard.capture()
        let cliService = PassCLIService(cliPath: "/usr/bin/pass", runner: BlockingLogoutRunner(gate: gate))
        let task = Task { @MainActor in
            try await delegate.logoutFromPassCLI(cliService: cliService, offlineModeService: fixture.service)
        }
        do {
            try await gate.waitUntilEntered()
            #expect(delegate.secretReleaseGuard.isCurrent(token) == false)
            await gate.open()
            try await task.value
            #expect(try await fixture.repository.hasPersistedSnapshots() == false)
        } catch {
            task.cancel()
            await gate.open()
            _ = await task.result
            throw error
        }
    }

    private func makeFixture(logoutError: CLIError?) async throws -> OfflineLogoutFixture {
        let base = try OfflineLifecycleFixture(itemIDs: ["item", "excluded"])
        let item = try #require(base.items.first { $0.id == "item" })
        let excluded = try #require(base.items.first { $0.id == "excluded" })
        let codec = base.codec()
        let service = OfflineModeService(repository: base.repository, codec: codec, cliService: OfflineFixtureViewer())
        try await initializeOfflineFixtureService(service)
        try await service.makeAvailableOffline(item: item, shareId: "share")
        try await service.selectWholeVault(true, vaultID: "vault")
        await service.waitUntilIdle()
        try await service.removeOfflineItem(itemId: excluded.id)
        return OfflineLogoutFixture(
            database: base.database,
            repository: base.repository,
            cliService: PassCLIService(cliPath: "/usr/bin/pass", runner: OfflineLogoutRunner(error: logoutError)),
            service: service
        )
    }
}

private struct OfflineLogoutFixture {
    let database: DatabaseManager
    let repository: OfflineSnapshotRepository
    let cliService: PassCLIService
    let service: OfflineModeService
}

private actor BlockingLogoutRunner: CLIRunning {
    let gate: OfflineTestGate

    init(gate: OfflineTestGate) { self.gate = gate }

    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        guard arguments == ["logout"] else { throw CLIError.commandFailed("unexpected command") }
        try? await gate.wait()
        return Data()
    }
}

private actor OfflineLogoutPreparationGate {
    private var isOpen = false
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        let entries = entryWaiters
        entryWaiters.removeAll()
        entries.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func open() {
        isOpen = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}

private actor OfflineLogoutCompletion {
    private var completed = false
    func markCompleted() { completed = true }
    func isCompleted() -> Bool { completed }
}

private func exclusionCount(_ database: DatabaseManager) async throws -> Int {
    try await database.reader.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineItemExclusions") ?? 0
    }
}

private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

private struct OfflineLogoutRunner: CLIRunning {
    let error: CLIError?
    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        guard arguments == ["logout"] else { throw CLIError.commandFailed("unexpected command") }
        if let error { throw error }
        return Data()
    }
}
