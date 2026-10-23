import Foundation
import Testing
import GRDB
@testable import Quick_Access_for_Pass

@Suite("Offline alias refresh races", .timeLimit(.minutes(1)))
struct OfflineAliasRefreshRaceTests {
    @Test func cancelledUpgradeBeforeAdmissionStaysPending() async throws {
        let fixture = try IncrementalOfflineSyncFixture(itemIDs: ["alias"])
        try await fixture.seedLegacyAliases()
        let before = try #require(try await fixture.snapshot("alias"))
        let generation = try await fixture.aliasRequestGeneration()
        let work = try await fixture.aliasWork([offlineAliasCLIItem(email: "synthetic@example.test")])
        let gate = IncrementalSyncGate()
        await fixture.codec.setGate(gate)
        let task = Task { try await fixture.consumeAlias(work) }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await fixture.snapshot("alias") == before)
        #expect(try await fixture.aliasMarker() == 0)
        #expect(try await fixture.aliasRequestGeneration() == generation)
    }

    @Test(arguments: [false, true]) func newerRetrySupersedesUpgrade(pending: Bool) async throws {
        let fixture = try IncrementalOfflineSyncFixture(itemIDs: ["alias"])
        try await fixture.seedLegacyAliases()
        let originalGeneration = try await fixture.aliasRequestGeneration()
        let work = try await fixture.aliasWork([offlineAliasCLIItem(email: "older@example.test")])
        let preparation = IncrementalSyncGate()
        await fixture.codec.setGate(preparation)
        let old = Task { try await fixture.consumeAlias(work) }
        await preparation.waitUntilEntered()
        await fixture.codec.setGate(nil)
        await fixture.viewer.setItems([try offlineAliasCLIItem(email: "newer@example.test")])
        let view = IncrementalSyncGate()
        if pending { await fixture.viewer.setGate(view) }
        #expect(try await fixture.service.retryOfflineItem(itemID: "alias", vaultID: "vault") == .submitted)
        if pending { await view.waitUntilEntered() } else { await fixture.service.waitUntilIdle() }
        let generation = try await fixture.aliasRequestGeneration()
        #expect(generation != originalGeneration)
        let state = try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "alias")
        let marker = try await fixture.aliasMarker()
        await preparation.open()
        try await old.value
        #expect(try await fixture.aliasRequestGeneration() == generation)
        #expect(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "alias") == state)
        #expect(try await fixture.aliasMarker() == marker)
        if pending { await view.open(); await fixture.service.waitUntilIdle() }
        let snapshot = try #require(try await fixture.snapshot("alias"))
        #expect(try await fixture.codec.decodeSnapshot(snapshot).aliasEmail == "newer@example.test")
        #expect(try await fixture.aliasMarker() == 1)
    }

    @Test(arguments: [false, true]) func removalAndPurgeCannotBeUndoneByUpgrade(purge: Bool) async throws {
        let fixture = try IncrementalOfflineSyncFixture(itemIDs: ["alias"])
        try await fixture.seedLegacyAliases()
        let work = try await fixture.aliasWork([offlineAliasCLIItem(email: "synthetic@example.test")])
        let gate = IncrementalSyncGate()
        await fixture.codec.setGate(gate)
        let old = Task { try await fixture.consumeAlias(work) }
        await gate.waitUntilEntered()
        if purge { try await fixture.service.removeAllOfflineData() }
        else { try await fixture.service.removeOfflineItem(itemId: "alias") }
        #expect(try await fixture.aliasRequestGeneration() == nil)
        await gate.open()
        try await old.value
        #expect(try await fixture.snapshot("alias") == nil)
        #expect(try await fixture.aliasMarker() == nil)
        #expect(try await fixture.repository.offlineItemSelection(itemId: "alias") == nil)
    }

    @Test func exclusionInvalidatesUpgrade() async throws {
        let fixture = try IncrementalOfflineSyncFixture(itemIDs: ["alias"])
        try await fixture.initialize()
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        try await fixture.sync([offlineAliasCLIItem()])
        #expect(try await fixture.aliasMarker() == 0)
        let work = try await fixture.aliasWork([offlineAliasCLIItem(email: "synthetic@example.test")])
        let gate = IncrementalSyncGate()
        await fixture.codec.setGate(gate)
        let task = Task { try await fixture.consumeAlias(work) }
        await gate.waitUntilEntered()
        try await fixture.service.removeOfflineItem(itemId: "alias")
        await gate.open()
        try await task.value
        #expect(try await fixture.snapshot("alias") == nil)
        #expect(try await fixture.aliasMarker() == nil)
        #expect(try await fixture.repository.itemPolicy(itemID: "alias", vaultID: "vault")?.isExcluded == true)
        await fixture.codec.setGate(nil)
        try await fixture.sync([offlineAliasCLIItem(email: "synthetic@example.test")])
        #expect(try await fixture.snapshot("alias") == nil)
    }

    @Test func cancellationAtWriterAdmissionStaysPending() async throws {
        let fixture = try IncrementalOfflineSyncFixture(itemIDs: ["alias"])
        try await fixture.seedLegacyAliases()
        let before = try await fixture.snapshot("alias")
        let generation = try await fixture.aliasRequestGeneration()
        let time = try await fixture.aliasTime()
        let work = try await fixture.aliasWork([offlineAliasCLIItem(email: "synthetic@example.test")])
        let publications = try await publications(fixture, work: work)
        let gate = OfflineTestGate()
        let repository = OfflineSnapshotRepository(database: fixture.database, beforePublication: { try? await gate.wait() })
        let task = Task { try await repository.publishSyncBatch(publications, capture: work.0) }
        try await gate.waitUntilEntered()
        task.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await fixture.snapshot("alias") == before)
        #expect(try await fixture.aliasMarker() == 0)
        #expect(try await fixture.aliasRequestGeneration() == generation)
        #expect(try await fixture.aliasTime() == time)
        await fixture.service.finishSyncCapture(work.0)
    }

    @Test func cancellationAfterCommitRetainsAliasCompletion() async throws {
        let keys = IncrementalPoolKeys()
        let fixture = try IncrementalOfflineSyncFixture(itemIDs: ["alias"], keyMaterialProvider: keys)
        try await fixture.seedLegacyAliases()
        let before = try await fixture.snapshot("alias")
        let generation = try await fixture.aliasRequestGeneration()
        let item = try offlineAliasCLIItem(email: "synthetic@example.test")
        let work = try await fixture.aliasWork([item])
        let publications = try await publications(fixture, work: work)
        let gate = OfflineTestGate()
        let repository = OfflineSnapshotRepository(database: fixture.database, afterPublication: { try? await gate.wait() })
        let task = Task { try await repository.publishSyncBatch(publications, capture: work.0) }
        try await gate.waitUntilEntered()
        let committed = try #require(try await fixture.snapshot("alias"))
        let committedGeneration = try await fixture.aliasRequestGeneration()
        #expect(committed != before)
        #expect(try await fixture.aliasMarker() == 1)
        #expect(committedGeneration != generation)
        #expect(try await fixture.aliasTime() == publications[0].refreshedAt)
        task.cancel()
        await gate.open()
        #expect(try await task.value == Set(publications.map { $0.work.key }))
        #expect(try await fixture.snapshot("alias") == committed)
        #expect(try await fixture.aliasMarker() == 1)
        #expect(try await fixture.aliasRequestGeneration() == committedGeneration)
        await fixture.service.finishSyncCapture(work.0)
        let count = await fixture.codec.counts().prepared
        let accesses = await keys.counts().lookups
        try await fixture.sync([item])
        #expect(await fixture.codec.counts().prepared == count)
        #expect(await keys.counts().lookups == accesses)
        #expect(await fixture.viewer.calls().isEmpty)
        #expect(try await fixture.snapshot("alias") == committed)
        #expect(try await fixture.aliasTime() == publications[0].refreshedAt)
    }

    @Test func partialSuccessResumesOnlyUnfinishedAliases() async throws {
        let fixture = try IncrementalOfflineSyncFixture(itemIDs: ["alias", "other"])
        try await fixture.seedLegacyAliases()
        let items = try fixture.itemIDs.map { try offlineAliasCLIItem(id: $0, email: "\($0)@example.test") }
        await fixture.codec.setFailures(["other"])
        try await fixture.sync(items)
        #expect(try await fixture.aliasMarker() == 1)
        #expect(try await fixture.aliasMarker("other") == 0)
        let completed = try await fixture.snapshot("alias")
        await fixture.service.stop()
        let recreated = try IncrementalOfflineSyncFixture(itemIDs: fixture.itemIDs, database: fixture.database, seedMetadata: false)
        try await recreated.initialize()
        try await recreated.sync(items)
        #expect(try await recreated.aliasMarker() == 1)
        #expect(try await recreated.aliasMarker("other") == 1)
        #expect(try await recreated.snapshot("alias") == completed)
        #expect(await recreated.codec.counts().prepared == 1)
    }

    @Test(arguments: [false, true]) func aliasBatchBoundaryAndPartialResume(failLast: Bool) async throws {
        let ids = (0..<33).map { String(format: "alias-%02d", $0) }
        let database = try DatabaseManager(inMemory: true, passphrase: Data("synthetic-alias-bounds".utf8))
        let wrapper = IncrementalSyncRepository(base: OfflineSnapshotRepository(database: database))
        let fixture = try IncrementalOfflineSyncFixture(itemIDs: ids, database: database, persisting: wrapper)
        try await fixture.seedLegacyAliases()
        #expect(await wrapper.batchCounts() == [32, 1])
        let items = try ids.map { try offlineAliasCLIItem(id: $0, email: "\($0)@example.test") }
        if failLast { await fixture.codec.setFailures([ids[32]]) }
        let gate = OfflineTestGate()
        await wrapper.setPublicationGate(gate)
        let task = Task { try await fixture.sync(items) }
        try await gate.waitUntilEntered()
        #expect(await fixture.codec.counts().prepared == (failLast ? 65 : 66))
        #expect(await fixture.codec.counts().peak == 1)
        #expect(await wrapper.batchCounts() == [32, 1, 32])
        await gate.open()
        _ = try await task.value
        #expect(await wrapper.batchCounts() == (failLast ? [32, 1, 32] : [32, 1, 32, 1]))
        #expect(await wrapper.batchBytes().allSatisfy { $0 <= OfflineSyncPublicationLimits.ciphertextBytes })
        for id in ids.prefix(32) { #expect(try await fixture.aliasMarker(id) == 1) }
        #expect(try await fixture.aliasMarker(ids[32]) == (failLast ? 0 : 1))
        let completed = try await fixture.snapshot(ids[0])
        await fixture.service.stop()
        let recreated = try IncrementalOfflineSyncFixture(itemIDs: ids, database: database, seedMetadata: false)
        try await recreated.initialize()
        try await recreated.sync(items)
        #expect(await recreated.codec.counts().prepared == (failLast ? 1 : 0))
        #expect(try await recreated.snapshot(ids[0]) == completed)
        for id in ids { #expect(try await recreated.aliasMarker(id) == 1) }
    }

    private func publications(_ fixture: IncrementalOfflineSyncFixture,
                              work: (OfflineSyncCapture, CLISyncFetchResult, MetadataSynchronizationResult)) async throws -> [OfflineSyncPublication] {
        let index = OfflineSyncResultIndex(work.1)
        let planned = try await fixture.repository.syncWork(capture: work.0, metadataProofs: work.2.offlineMetadataProofs,
            sourceTimes: index.sourceTimes, allowMembershipExpansion: true, contentRefreshCandidates: index.contentRefreshCandidates)
        #expect(planned.count == 1)
        var publications: [OfflineSyncPublication] = []
        for candidate in planned {
            #expect(candidate.requiresContentRefresh)
            let prepared = try await fixture.codec.prepareSnapshot(from: work.1.items[0].item,
                for: OfflineSnapshotPreparationIdentity(key: candidate.key, shareID: candidate.shareID, itemType: candidate.itemType))
            publications.append(OfflineSyncPublication(work: candidate, prepared: prepared, refreshedAt: Date(timeIntervalSince1970: 100), source: .syncList))
        }
        return publications
    }
}
