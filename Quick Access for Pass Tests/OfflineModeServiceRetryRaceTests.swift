import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Offline item retry candidate races", .timeLimit(.minutes(1)))
struct OfflineModeServiceRetryRaceTests {
    @Test func itemRetryRequiresSuccessfulStartupRecovery() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["target"])
        _ = try await fixture.repository.selectItemManually(itemID: "target", vaultID: "vault", shareID: "share")
        let viewer = OfflineFixtureViewer()
        let service = fixture.service(viewer: viewer)
        await #expect(throws: OfflineModeService.Error.notInitialized) {
            try await service.retryOfflineItem(itemID: "target", vaultID: "vault")
        }
        #expect(await viewer.callCount(itemID: "target") == 0)
        #expect(try await fixture.repository.offlineItemSelection(itemId: "target")?.cacheStatus == .notCached)
        await service.stop()
    }

    @Test func capturedCandidateCannotFetchAfterRemovalAndReselection() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["target"])
        let gate = OfflineTestGate()
        let repository = SelectionCandidateGatedRepository(base: fixture.repository, gate: gate)
        let fetchGate = OfflineTestGate()
        let viewer = OfflineFixtureViewer(beforeView: { try await fetchGate.wait() })
        let service = OfflineModeService(repository: repository, codec: fixture.codec(), cliService: viewer)
        try await initializeOfflineFixtureService(service)
        let item = try #require(fixture.items.first)
        _ = try await fixture.repository.selectItemManually(itemID: "target", vaultID: "vault", shareID: "share")

        let oldRetry = Task { try await service.retryOfflineItem(itemID: "target", vaultID: "vault") }
        try await gate.waitUntilEntered()
        try await service.removeOfflineItem(itemId: "target")
        let reselection = Task { try await service.makeAvailableOffline(item: item, shareId: "share") }
        try await fetchGate.waitUntilEntered()
        let current = try #require(try await fixture.repository.offlineItemSelection(itemId: "target"))
        let currentGeneration = current.selectionGeneration
        #expect(current.cacheStatus == .notCached)

        await gate.open()
        #expect(try await oldRetry.value == .unavailable)
        await fetchGate.open()
        try await reselection.value
        await service.waitUntilIdle()
        #expect(await viewer.callCount(itemID: "target") == 1)
        #expect(try await fixture.repository.offlineItemSelection(itemId: "target")?.selectionGeneration == currentGeneration)
        await service.stop()
    }

    @Test func capturedCandidateCannotFetchAfterRemovalCreatesExclusion() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["target"])
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        let gate = OfflineTestGate()
        let repository = SelectionCandidateGatedRepository(base: fixture.repository, gate: gate)
        let viewer = OfflineFixtureViewer()
        let service = OfflineModeService(repository: repository, codec: fixture.codec(), cliService: viewer)
        try await initializeOfflineFixtureService(service)
        _ = try await fixture.repository.selectItemManually(itemID: "target", vaultID: "vault", shareID: "share")

        let oldRetry = Task { try await service.retryOfflineItem(itemID: "target", vaultID: "vault") }
        try await gate.waitUntilEntered()
        try await service.removeOfflineItem(itemId: "target")
        await gate.open()
        #expect(try await oldRetry.value == .unavailable)
        await service.waitUntilIdle()
        #expect(await viewer.callCount(itemID: "target") == 0)
        #expect(try await fixture.repository.offlineItemSelection(itemId: "target") == nil)
        #expect(try await fixture.repository.itemPolicy(itemID: "target", vaultID: "vault")?.isExcluded == true)
        await service.stop()
    }

    @Test func capturedCandidateCannotFetchAfterItemMovesVaults() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["target"])
        let gate = OfflineTestGate()
        let repository = SelectionCandidateGatedRepository(base: fixture.repository, gate: gate)
        let viewer = OfflineFixtureViewer()
        let service = OfflineModeService(repository: repository, codec: fixture.codec(), cliService: viewer)
        try await initializeOfflineFixtureService(service)
        _ = try await fixture.repository.selectItemManually(itemID: "target", vaultID: "vault", shareID: "share")

        let staleRetry = Task { try await service.retryOfflineItem(itemID: "target", vaultID: "vault") }
        try await gate.waitUntilEntered()
        try fixture.database.upsertVaults([PassVault(id: "other", name: "Other", shareId: "other-share")])
        let source = try #require(fixture.items.first)
        try fixture.database.upsertItems([PassItem(id: source.id, vaultId: "other", title: source.title,
            itemType: source.itemType, subtitle: source.subtitle, url: source.url, hasTOTP: source.hasTOTP,
            state: source.state, createTime: source.createTime, modifyTime: source.modifyTime,
            useCount: source.useCount, lastUsedAt: source.lastUsedAt)])
        await gate.open()
        #expect(try await staleRetry.value == .submitted)
        await service.waitUntilIdle()
        #expect(await viewer.callCount(itemID: "target") == 0)
        #expect(try fixture.database.allActiveItems().first?.vaultId == "other")
        #expect(try await fixture.repository.offlineItemSelection(itemId: "target")?.cacheStatus != .cached)
        #expect(try await fixture.repository.hasAuthorizedSnapshot(for: OfflineSnapshotKey(
            vaultId: "vault", itemId: "target", schemaVersion: OfflineSnapshotLimits.schemaVersion
        )) == false)
        await service.stop()
    }

    @Test func capturedCandidateIsRejectedAfterServiceStop() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["target"])
        let gate = OfflineTestGate()
        let repository = SelectionCandidateGatedRepository(base: fixture.repository, gate: gate)
        let viewer = OfflineFixtureViewer()
        let service = OfflineModeService(repository: repository, codec: fixture.codec(), cliService: viewer)
        try await initializeOfflineFixtureService(service)
        _ = try await fixture.repository.selectItemManually(itemID: "target", vaultID: "vault", shareID: "share")

        let staleRetry = Task { try await service.retryOfflineItem(itemID: "target", vaultID: "vault") }
        try await gate.waitUntilEntered()
        await service.stop()
        await gate.open()
        #expect(try await staleRetry.value == .unavailable)
        await service.waitUntilIdle()
        #expect(await viewer.callCount(itemID: "target") == 0)
        #expect(try await fixture.repository.offlineItemSelection(itemId: "target")?.cacheStatus == .notCached)
    }

    @Test func candidateMaterializationUsesCurrentObservationButRefreshKeepsExistingPolicy() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["target"])
        let gate = OfflineTestGate()
        let repository = SelectionCandidateGatedRepository(base: fixture.repository, gate: gate)
        let viewer = OfflineFixtureViewer()
        let service = OfflineModeService(repository: repository, codec: fixture.codec(), cliService: viewer)
        try await initializeOfflineFixtureService(service)
        _ = try await fixture.repository.selectItemManually(itemID: "target", vaultID: "vault", shareID: "share")

        let materialization = Task { try await service.retryOfflineItem(itemID: "target", vaultID: "vault") }
        try await gate.waitUntilEntered()
        await service.updateSelectionObservation(generation: offlineFixtureObservationGeneration, status: .failed)
        await gate.open()
        #expect(try await materialization.value == .submitted)
        await service.waitUntilIdle()
        #expect(await viewer.callCount(itemID: "target") == 0)
        #expect(try await fixture.repository.offlineItemSelection(itemId: "target")?.cacheStatus == .notCached)

        let freshGeneration = UUID()
        await service.updateSelectionObservation(generation: freshGeneration, status: .starting)
        await service.updateSelectionObservation(generation: freshGeneration, status: .fresh)
        try await service.makeAvailableOffline(item: try #require(fixture.items.first), shareId: "share")
        let refreshGate = OfflineTestGate()
        await repository.setGate(refreshGate)
        let refresh = Task { try await service.retryOfflineItem(itemID: "target", vaultID: "vault") }
        try await refreshGate.waitUntilEntered()
        await service.updateSelectionObservation(generation: freshGeneration, status: .failed)
        await refreshGate.open()
        #expect(try await refresh.value == .submitted)
        await service.waitUntilIdle()
        #expect(await viewer.callCount(itemID: "target") == 2)
        #expect(try await fixture.repository.offlineItemSelection(itemId: "target")?.cacheStatus == .cached)
        await service.stop()
    }
}

/// Captures the scoped current candidate first, then holds its return to the service.
private actor SelectionCandidateGatedRepository: OfflineSnapshotPersisting {
    private let base: OfflineSnapshotRepository
    private var gate: OfflineTestGate?
    nonisolated var releaseAuthority: OfflineReleaseAuthority { base.releaseAuthority }

    init(base: OfflineSnapshotRepository, gate: OfflineTestGate) {
        self.base = base
        self.gate = gate
    }

    func setGate(_ gate: OfflineTestGate) { self.gate = gate }

    func releaseProof(for snapshot: EncryptedOfflineSnapshot) async throws -> OfflineReleaseProof? { try await base.releaseProof(for: snapshot) }
    func beginRequest(itemID: String, vaultID: String, shareID: String, kind: OfflineRequestKind,
                      expectations: OfflineRequestExpectations) async throws -> OfflineRequestToken? {
        try await base.beginRequest(itemID: itemID, vaultID: vaultID, shareID: shareID, kind: kind,
                                    expectations: expectations)
    }
    func publish(_ snapshot: EncryptedOfflineSnapshot, for request: OfflineRequestToken, refreshedAt: Date) async throws -> Bool {
        try await base.publish(snapshot, for: request, refreshedAt: refreshedAt)
    }
    func finishRequest(_ request: OfflineRequestToken, failed: Bool) async throws { try await base.finishRequest(request, failed: failed) }
    func setVaultSelected(_ selected: Bool, vaultID: String) async throws -> OfflineVaultSelection? { try await base.setVaultSelected(selected, vaultID: vaultID) }
    func selectItemManually(itemID: String, vaultID: String, shareID: String) async throws -> UUID {
        try await base.selectItemManually(itemID: itemID, vaultID: vaultID, shareID: shareID)
    }
    func keepItemOfflineIndividually(itemID: String, vaultID: String) async throws { try await base.keepItemOfflineIndividually(itemID: itemID, vaultID: vaultID) }
    func itemPolicy(itemID: String, vaultID: String) async throws -> OfflineItemPolicy? { try await base.itemPolicy(itemID: itemID, vaultID: vaultID) }
    func workCandidates(vaultID: String?, includeNewSelections: Bool, refreshExisting: Bool) async throws -> [OfflineSnapshotWorkCandidate] {
        try await base.workCandidates(vaultID: vaultID, includeNewSelections: includeNewSelections, refreshExisting: refreshExisting)
    }
    func workCandidateForSelectedItem(itemID: String, vaultID: String) async throws -> OfflineSnapshotWorkCandidate? {
        let captured = try await base.workCandidateForSelectedItem(itemID: itemID, vaultID: vaultID)
        guard captured != nil, let gate else { return captured }
        self.gate = nil
        try await gate.wait()
        return captured
    }
    func removeItem(_ itemID: String) async throws { try await base.removeItem(itemID) }
    func purge() async throws { try await base.purge() }
    func recoverAbandonedRequests() async throws { try await base.recoverAbandonedRequests() }
    func authorizedSnapshot(for key: OfflineSnapshotKey) async throws -> EncryptedOfflineSnapshot? { try await base.authorizedSnapshot(for: key) }
    func hasAuthorizedSnapshot(for key: OfflineSnapshotKey) async throws -> Bool { try await base.hasAuthorizedSnapshot(for: key) }
    func isAuthorized(_ snapshot: EncryptedOfflineSnapshot) async throws -> Bool { try await base.isAuthorized(snapshot) }
    func discardCorruptSnapshot(_ snapshot: EncryptedOfflineSnapshot) async throws { try await base.discardCorruptSnapshot(snapshot) }
    func hasPersistedSnapshots() async throws -> Bool { try await base.hasPersistedSnapshots() }
    func offlineVaultIds() async throws -> Set<String> { try await base.offlineVaultIds() }
    func offlineItemSelection(itemId: String) async throws -> OfflineItemSelection? { try await base.offlineItemSelection(itemId: itemId) }
    func offlineItemSelections() async throws -> [OfflineItemSelection] { try await base.offlineItemSelections() }
}
