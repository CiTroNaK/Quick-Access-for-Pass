import Foundation
import Testing
import GRDB
@testable import Quick_Access_for_Pass

@Suite("One-time offline alias refresh", .timeLimit(.minutes(1)))
struct OfflineAliasRefreshTests {
    @Test func sameSourceLegacyAliasRefreshesOnce() async throws {
        let keys = IncrementalPoolKeys()
        let fixture = try IncrementalOfflineSyncFixture(itemIDs: ["alias"], keyMaterialProvider: keys)
        try await fixture.seedLegacyAliases()
        let before = try #require(try await fixture.snapshot("alias"))
        let selected = try await fixture.repository.offlineItemSelection(itemId: "alias")?.selectionGeneration
        let item = try offlineAliasCLIItem(email: "synthetic@example.test")
        try await fixture.sync([item])
        let after = try #require(try await fixture.snapshot("alias"))
        #expect(after.payload != before.payload)
        #expect(try await fixture.aliasMarker() == 1)
        #expect(try await fixture.codec.decodeSnapshot(after).aliasEmail == item.aliasEmail)
        #expect(try await fixture.repository.offlineItemSelection(itemId: "alias")?.selectionGeneration == selected)
        let time = try await fixture.aliasTime()
        let prepared = await fixture.codec.counts().prepared
        let accesses = await keys.counts().lookups
        try await fixture.sync([item])
        #expect(try await fixture.snapshot("alias") == after)
        #expect(try await fixture.aliasTime() == time)
        #expect(await fixture.codec.counts().prepared == prepared)
        #expect(await keys.counts().lookups == accesses)
        #expect(await fixture.viewer.calls().isEmpty)
    }

    @Test(arguments: [1, 2])
    func currentAndNewerRevisionsDoNotForceUnchangedRefresh(contentRevision: Int) async throws {
        let keys = IncrementalPoolKeys()
        let fixture = try IncrementalOfflineSyncFixture(itemIDs: ["alias"], keyMaterialProvider: keys)
        try await fixture.seedLegacyAliases()
        let item = try offlineAliasCLIItem(email: "synthetic@example.test")
        try await fixture.sync([item])
        // Test-only fixture for an already-certified current/newer snapshot; production always uses the codec.
        try await fixture.database.writer.write { db in
            try db.execute(sql: "UPDATE offlineSnapshots SET contentRevision = ? WHERE itemId = 'alias'",
                           arguments: [contentRevision])
        }
        let before = try #require(try await fixture.snapshot("alias"))
        let time = try await fixture.aliasTime()
        let count = await fixture.codec.counts().prepared
        let accesses = await keys.counts().lookups
        try await fixture.sync([item])
        #expect(try await fixture.snapshot("alias") == before)
        #expect(try await fixture.aliasMarker() == contentRevision)
        #expect(try await fixture.aliasTime() == time)
        #expect(await fixture.codec.counts().prepared == count)
        #expect(await keys.counts().lookups == accesses)
        #expect(await fixture.viewer.calls().isEmpty)
    }

    @Test func upgradePublicationRejectsInsufficientPreparedRevision() async throws {
        let fixture = try IncrementalOfflineSyncFixture(itemIDs: ["alias"])
        try await fixture.seedLegacyAliases()
        let before = try #require(try await fixture.snapshot("alias"))
        let generation = try await fixture.aliasRequestGeneration()
        let item = try offlineAliasCLIItem(email: "synthetic@example.test")
        let work = try await fixture.aliasWork([item])
        let index = OfflineSyncResultIndex(work.1)
        let candidate = try #require(try await fixture.repository.syncWork(
            capture: work.0, metadataProofs: work.2.offlineMetadataProofs,
            sourceTimes: index.sourceTimes, allowMembershipExpansion: true,
            contentRefreshCandidates: index.contentRefreshCandidates
        ).first)
        try #require(candidate.requiresContentRefresh)
        let prepared = try await fixture.codec.prepareSnapshot(from: item, for: OfflineSnapshotPreparationIdentity(
            key: candidate.key, shareID: candidate.shareID, itemType: candidate.itemType
        ))
        let insufficient = PreparedOfflineSnapshot(snapshot: prepared.snapshot, sourceModifyTime: prepared.sourceModifyTime,
                                                   contentRevision: 0)
        let publication = OfflineSyncPublication(work: candidate, prepared: insufficient, refreshedAt: .now, source: .syncList)
        #expect(try await fixture.repository.publishSyncBatch([publication], capture: work.0).isEmpty)
        #expect(try await fixture.snapshot("alias") == before)
        #expect(try await fixture.aliasMarker() == 0)
        #expect(try await fixture.aliasRequestGeneration() == generation)
        await fixture.service.finishSyncCapture(work.0)
    }

    @Test func completedRefreshSurvivesRecreation() async throws {
        let fixture = try IncrementalOfflineSyncFixture(itemIDs: ["alias"])
        try await fixture.seedLegacyAliases()
        let item = try offlineAliasCLIItem(email: "synthetic@example.test")
        try await fixture.sync([item])
        let before = try #require(try await fixture.snapshot("alias"))
        let time = try await fixture.aliasTime()
        await fixture.service.stop()
        let keys = IncrementalPoolKeys()
        let recreated = try IncrementalOfflineSyncFixture(itemIDs: ["alias"], database: fixture.database, seedMetadata: false, keyMaterialProvider: keys)
        try await recreated.initialize()
        try await recreated.sync([item])
        #expect(try await recreated.snapshot("alias") == before)
        #expect(try await recreated.aliasMarker() == 1)
        #expect(try await recreated.aliasTime() == time)
        #expect(await recreated.codec.counts().prepared == 0)
        #expect(await recreated.viewer.calls().isEmpty)
        #expect(await keys.counts().lookups == 0)
    }

    @Test(arguments: [nil, "", " \n\t"] as [String?])
    func absentEmailDefersUpgrade(email: String?) async throws {
        let fixture = try IncrementalOfflineSyncFixture(itemIDs: ["alias"])
        try await fixture.seedLegacyAliases()
        let before = try await fixture.snapshot("alias")
        let count = await fixture.codec.counts().prepared
        let time = try await fixture.aliasTime()
        try await fixture.sync([offlineAliasCLIItem(email: email)])
        #expect(try await fixture.snapshot("alias") == before)
        #expect(try await fixture.aliasMarker() == 0)
        #expect(try await fixture.aliasTime() == time)
        #expect(await fixture.codec.counts().prepared == count)
        #expect(await fixture.viewer.calls().isEmpty)
    }

    @Test func missingTopLevelEmailDefersUpgrade() async throws {
        let fixture = try IncrementalOfflineSyncFixture(itemIDs: ["alias"])
        try await fixture.seedLegacyAliases()
        let before = try await fixture.snapshot("alias")
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(offlineAliasCLIItem())) as? [String: Any])
        object.removeValue(forKey: "alias_email")
        let item = try JSONDecoder().decode(CLIItem.self, from: JSONSerialization.data(withJSONObject: object))
        let result = try fixture.result([item])
        #expect(OfflineSyncResultIndex(result).contentRefreshCandidates.isEmpty)
        let count = await fixture.codec.counts().prepared
        try await fixture.sync([item])
        #expect(try await fixture.snapshot("alias") == before)
        #expect(try await fixture.aliasMarker() == 0)
        #expect(await fixture.codec.counts().prepared == count)
        #expect(await fixture.viewer.calls().isEmpty)
    }

    @Test func unselectedAndNonAliasItemsAreUnaffected() async throws {
        let keys = IncrementalPoolKeys()
        let fixture = try IncrementalOfflineSyncFixture(itemIDs: ["alias", "login"], keyMaterialProvider: keys)
        try await fixture.initialize()
        try await fixture.select(["login"])
        let login = try incrementalSyncCLIItem(id: "login")
        try await fixture.sync([offlineAliasCLIItem(), login])
        let before = try await fixture.snapshot("login")
        let count = await fixture.codec.counts().prepared
        let accesses = await keys.counts().lookups
        try await fixture.sync([offlineAliasCLIItem(email: "synthetic@example.test"), login])
        #expect(try await fixture.snapshot("alias") == nil)
        #expect(try await fixture.snapshot("login") == before)
        #expect(try await fixture.aliasMarker("login") == 0)
        #expect(await fixture.codec.counts().prepared == count)
        #expect(await keys.counts().lookups == accesses)
        #expect(await fixture.viewer.calls().isEmpty)
    }

    @Test func newAliasSnapshotNeedsNoUpgrade() async throws {
        let fixture = try IncrementalOfflineSyncFixture(itemIDs: ["alias"])
        try await fixture.initialize()
        try await fixture.select()
        let item = try offlineAliasCLIItem(email: "synthetic@example.test")
        try await fixture.sync([item])
        #expect(try await fixture.aliasMarker() == 1)
        let before = try await fixture.snapshot("alias")
        let count = await fixture.codec.counts().prepared
        try await fixture.sync([item])
        #expect(try await fixture.snapshot("alias") == before)
        #expect(await fixture.codec.counts().prepared == count)
    }

    @Test(arguments: [false, true]) func candidateEvidenceSurvivesRepositoryForwarding(fallback: Bool) async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("synthetic-alias-forwarding".utf8))
        let wrapper = IncrementalSyncRepository(base: OfflineSnapshotRepository(database: database))
        let storage: any OfflineSnapshotPersisting = wrapper
        let fixture = try IncrementalOfflineSyncFixture(itemIDs: ["alias"], database: database, persisting: storage)
        try await fixture.seedLegacyAliases()
        let before = try await fixture.snapshot("alias")
        let item = try offlineAliasCLIItem(email: "synthetic@example.test")
        await fixture.viewer.setItems([item])
        try await fixture.sync([item], provenance: fallback ? .unavailable : .completeJSONV1)
        #expect(try await fixture.aliasMarker() == 1)
        #expect(try await fixture.snapshot("alias") != before)
        #expect(await fixture.viewer.calls() == (fallback ? ["alias"] : []))
        #expect(await wrapper.batchCounts() == [1, 1])
    }

    @Test(arguments: ["duplicateKey", "duplicateID", "vault", "share"])
    func ambiguousAliasEvidenceCannotForceRefresh(ambiguity: String) async throws {
        let fixture = try IncrementalOfflineSyncFixture(itemIDs: ["alias"])
        try await fixture.seedLegacyAliases()
        let good = try offlineAliasCLIItem(email: "synthetic@example.test")
        let work = try await fixture.aliasWork([good])
        var items: [(item: CLIItem, vaultId: String)] = [(good, "vault")]
        switch ambiguity {
        case "duplicateKey": items.append((good, "vault"))
        case "duplicateID": items.append((try offlineAliasCLIItem(vaultID: "other", shareID: "other-share", email: "other@example.test"), "other"))
        case "vault": items = [(try offlineAliasCLIItem(vaultID: "wrong", email: "synthetic@example.test"), "vault")]
        default: items = [(try offlineAliasCLIItem(shareID: "wrong", email: "synthetic@example.test"), "vault")]
        }
        let result = CLISyncFetchResult(vaults: work.1.vaults, items: items, skippedItems: [], presenceUncertainties: [])
        let index = OfflineSyncResultIndex(result)
        #expect(index.contentRefreshCandidates.isEmpty)
        let withEvidence = try await fixture.repository.syncWork(capture: work.0, metadataProofs: work.2.offlineMetadataProofs,
            sourceTimes: index.sourceTimes, allowMembershipExpansion: true, contentRefreshCandidates: index.contentRefreshCandidates)
        let ordinary = try await fixture.repository.syncWork(capture: work.0, metadataProofs: work.2.offlineMetadataProofs,
            sourceTimes: index.sourceTimes, allowMembershipExpansion: true, contentRefreshCandidates: [])
        #expect(withEvidence.count == ordinary.count)
        #expect(zip(withEvidence, ordinary).allSatisfy { OfflineSnapshotRepository.sameSyncWork($0, $1) })
        #expect(withEvidence.allSatisfy { $0.requiresContentRefresh == false })
        #expect(try await fixture.aliasMarker() == 0)
        await fixture.service.finishSyncCapture(work.0)
    }

    @Test func trustworthyFallbackCanCompleteDespiteAmbiguousList() async throws {
        let fixture = try IncrementalOfflineSyncFixture(itemIDs: ["alias"])
        try await fixture.seedLegacyAliases()
        let good = try offlineAliasCLIItem(email: "synthetic@example.test")
        let work = try await fixture.aliasWork([good], provenance: .unavailable)
        let ambiguous = CLISyncFetchResult(vaults: work.1.vaults, items: [(good, "vault"), (good, "vault")],
            skippedItems: [], presenceUncertainties: [], contentProvenanceByVaultID: ["vault": .unavailable])
        #expect(OfflineSyncResultIndex(ambiguous).contentRefreshCandidates.isEmpty)
        await fixture.viewer.setItems([good])
        try await fixture.consumeAlias((work.0, ambiguous, work.2))
        #expect(await fixture.viewer.calls() == ["alias"])
        #expect(try await fixture.aliasMarker() == 1)
    }

    @Test func fallbackFailureKeepsOldCopyAndLaterSyncRetries() async throws {
        let fixture = try IncrementalOfflineSyncFixture(itemIDs: ["alias"])
        try await fixture.seedLegacyAliases()
        let before = try #require(try await fixture.snapshot("alias"))
        let item = try offlineAliasCLIItem(email: "synthetic@example.test")
        try await fixture.sync([item], provenance: .unavailable)
        #expect(try await fixture.snapshot("alias") == before)
        #expect(try await fixture.aliasMarker() == 0)
        #expect(try await fixture.repository.isAuthorized(before))
        await fixture.viewer.setItems([item])
        try await fixture.sync([item], provenance: .unavailable)
        #expect(try await fixture.snapshot("alias") != before)
        #expect(try await fixture.aliasMarker() == 1)
    }

    @Test(arguments: [nil, " \n"] as [String?]) func fallbackWithoutEmailDefers(email: String?) async throws {
        let fixture = try IncrementalOfflineSyncFixture(itemIDs: ["alias"])
        try await fixture.seedLegacyAliases()
        let before = try await fixture.snapshot("alias")
        let generation = try await fixture.aliasRequestGeneration()
        let count = await fixture.codec.counts().prepared
        await fixture.viewer.setItems([try offlineAliasCLIItem(email: email)])
        try await fixture.sync([offlineAliasCLIItem(email: "synthetic@example.test")], provenance: .unavailable)
        #expect(try await fixture.snapshot("alias") == before)
        #expect(try await fixture.aliasMarker() == 0)
        #expect(try await fixture.aliasRequestGeneration() == generation)
        #expect(await fixture.codec.counts().prepared == count)
    }
}
