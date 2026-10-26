import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Explicit folder publication admission", .timeLimit(.minutes(1)))
struct OfflineFolderExplicitPublicationTests {
    @Test(arguments: [false, true], ["checking", "downgrade", "selection", "deferred", "reverified"])
    func staleFolderAdmissionCannotPublish(existing: Bool, transition: String) async throws {
        let f = try await OfflineFolderFixture.make()
        let policy = try #require(try await f.select("parent"))
        if existing { try await f.cache(policy) }
        let barrier = IncrementalSyncGate()
        let repository = OfflineSnapshotRepository(database: f.database, beforePublication: { await barrier.wait() }, folderFeatureGate: f.gate)
        let request = try #require(try await repository.beginRequest(itemID: "item", vaultID: "vault", shareID: "share",
            kind: existing ? .refresh : .folderSelection(folderID: "parent", policyGeneration: policy.generation)))
        let item = try offlineTestCLIItem(id: "item", vaultID: "vault", shareID: "share", password: "replacement", modifyTime: "1970-01-01T00:00:02Z")
        let prepared = try await f.codec().prepareSnapshot(from: item, for: request)
        let before = try await f.snapshot()
        let beforeTime = try await repository.offlineItemSelection(itemId: "item")?.lastRefreshedAt
        let publication = Task { try await repository.publish(prepared, for: request, refreshedAt: Date(timeIntervalSince1970: 99)) }
        await barrier.waitUntilEntered()
        switch transition {
        case "checking": _ = f.gate.beginProbe()
        case "downgrade": f.gate.confirm(capabilities: .init(rawVersionString: "2.4.2"), for: f.gate.beginProbe())
        case "selection": f.gate.invalidateSelection()
        case "deferred": try await f.synchronize(failure: true)
        default:
            f.gate.confirm(capabilities: .init(rawVersionString: "2.5.1"), for: f.gate.beginProbe())
            try await f.synchronize()
        }
        await barrier.open()
        #expect(try await publication.value == false)
        let after = try await f.snapshot()
        #expect(after?.payload == before?.payload)
        #expect(try await repository.offlineItemSelection(itemId: "item")?.lastRefreshedAt == beforeTime)
        #expect((after != nil) == existing)
        try await repository.removeItem("item")
        #expect(try await f.snapshot() == nil)
    }

    @Test(arguments: [false, true], [false, true])
    func independentConsentSurvivesFolderDeferral(vault: Bool, deferred: Bool) async throws {
        let f = try await OfflineFolderFixture.make()
        _ = try await f.select("parent")
        let kind: OfflineRequestKind
        if vault {
            let selection = try #require(try await f.repository.setVaultSelected(true, vaultID: "vault"))
            kind = .vaultSelection(policyGeneration: selection.generation)
        } else { kind = .selection }
        let request = try #require(try await f.repository.beginRequest(itemID: "item", vaultID: "vault", shareID: "share", kind: kind))
        let item = try offlineTestCLIItem(id: "item", vaultID: "vault", shareID: "share", password: "independent", modifyTime: "1970-01-01T00:00:02Z")
        let prepared = try await f.codec().prepareSnapshot(from: item, for: request)
        if deferred { try await f.synchronize(failure: true) } else { _ = f.gate.beginProbe() }
        #expect(try await f.repository.publish(prepared, for: request, refreshedAt: Date(timeIntervalSince1970: 99)))
        #expect(try await f.snapshot() != nil)
    }

    @Test(arguments: [false, true])
    func scheduledExplicitWorkRechecksBeforePublication(existing: Bool) async throws {
        let f = try await OfflineFolderFixture.make()
        let policy = try #require(try await f.select("parent"))
        if existing { try await f.cache(policy) }
        let before = try await f.snapshot()
        let barrier = IncrementalSyncGate()
        let repository = OfflineSnapshotRepository(database: f.database, beforePublication: { await barrier.wait() }, folderFeatureGate: f.gate)
        let service = OfflineModeService(repository: repository, codec: f.codec(), cliService: OfflineFixtureViewer())
        try await service.initialize()
        let observation = UUID()
        await service.updateSelectionObservation(generation: observation, status: .starting)
        await service.updateSelectionObservation(generation: observation, status: .fresh)
        if existing {
            #expect(try await service.retryOfflineItem(itemID: "item", vaultID: "vault") == .submitted)
        } else {
            try await service.selectFolder(true, folderID: "parent", vaultID: "vault", featureStamp: f.gate.supportedStamp())
        }
        await barrier.waitUntilEntered()
        _ = f.gate.beginProbe()
        await barrier.open()
        await service.waitUntilIdle()
        let after = try await f.snapshot()
        #expect(after?.payload == before?.payload)
        #expect((after != nil) == existing)
        await service.stop()
    }
}
