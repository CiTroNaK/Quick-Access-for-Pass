import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Folder sync transaction proof binding", .timeLimit(.minutes(1)))
@MainActor
struct OfflineFolderSyncProofTests {
    @Test("The same live operation cannot substitute a later catalog or downgraded support", arguments: [false, true])
    func originalProofOnly(changedCatalog: Bool) async throws {
        let fixture = try await OfflineFolderSyncFixture.make()
        let operation = fixture.folder.database.beginSyncOperation()
        let capture = try await fixture.folder.repository.beginSyncCapture(operation: operation, lifecycleGeneration: UUID())
        let fetched = try await fixture.cli.fetchAllItems(folderFeatureStamp: fixture.cli.folderFeatureGate.supportedStamp())
        let metadata = try await fixture.commit(fetched, operation: operation)
        let times = Dictionary(uniqueKeysWithValues: metadata.offlineMetadataProofs.values.map { ($0.item.id, $0.item.modifyTime) })
        let planned = try await fixture.folder.repository.syncWork(capture: capture, metadataProofs: metadata.offlineMetadataProofs,
            sourceTimes: times, allowMembershipExpansion: true)
        let work = try #require(planned.first { $0.key.itemId == "new" })
        guard case .folderMember(let folderID, _, let membership, let known) = work.ownership else {
            Issue.record("New member needs captured folder ownership")
            return
        }
        #expect(folderID == "parent")
        #expect(!known)
        #expect(membership == work.metadataProof.folderCatalogProof?.membershipGeneration)
        let item = try #require(fetched.items.first { $0.item.id == "new" }?.item)
        let prepared = try await fixture.codec.prepareSnapshot(from: item,
            for: OfflineSnapshotPreparationIdentity(key: work.key, shareID: work.shareID, itemType: work.itemType))
        if changedCatalog {
            // The item's own ancestry remains unchanged: rejection must bind the original catalog proof,
            // not merely notice operation cancellation, an item move, or loss of the selected policy.
            try await fixture.replaceCatalog(otherParent: "parent", operation: operation)
        } else {
            let gate = fixture.cli.folderFeatureGate
            gate.confirm(capabilities: .init(rawVersionString: "2.4.2"), for: gate.beginProbe())
        }
        #expect(operation.isCurrent)
        let publication = OfflineSyncPublication(work: work, prepared: prepared, refreshedAt: Date(), source: .syncList)
        #expect(try await fixture.folder.repository.publishSyncBatch([publication], capture: capture).isEmpty)
        #expect(try await fixture.snapshot() == nil)
        try await fixture.folder.repository.endSyncCapture(capture)
        await fixture.finish()
    }

    @Test("Already selected folder copies retain exact selection/request ownership")
    func selectedOwnershipIsStronger() async throws {
        let fixture = try await OfflineFolderSyncFixture.make()
        try await fixture.sync()
        _ = try #require(try await fixture.snapshot())
        await fixture.runner.setSourceTime("1970-01-01T00:00:03Z")
        let operation = fixture.folder.database.beginSyncOperation()
        let capture = try await fixture.folder.repository.beginSyncCapture(operation: operation, lifecycleGeneration: UUID())
        let fetched = try await fixture.cli.fetchAllItems(folderFeatureStamp: fixture.cli.folderFeatureGate.supportedStamp())
        let metadata = try await fixture.commit(fetched, operation: operation)
        let times = Dictionary(uniqueKeysWithValues: metadata.offlineMetadataProofs.values.map { ($0.item.id, $0.item.modifyTime) })
        let work = try await fixture.folder.repository.syncWork(capture: capture, metadataProofs: metadata.offlineMetadataProofs,
            sourceTimes: times, allowMembershipExpansion: true)
        #expect(work.count == 2)
        #expect(work.allSatisfy { if case .selected = $0.ownership { true } else { false } })
        try await fixture.folder.repository.endSyncCapture(capture)
        await fixture.finish()
    }
}
