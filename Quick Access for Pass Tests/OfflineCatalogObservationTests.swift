import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("OfflineCatalogObservation")
struct OfflineCatalogObservationTests {
    @Test func manualSelectionProjectsWithoutWholeVaultPolicy() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        _ = try await fixture.repository.selectItemManually(itemID: "item", vaultID: "vault", shareID: "share")

        let projection = try await fixture.database.reader.read { db in
            try OfflineCatalogObservation.presentation(in: db)
        }

        #expect(projection.selectedVaultIDs.isEmpty)
        #expect(projection.policyByItemID["item"]?.isManuallySelected == true)
        #expect(projection.vaults.first?.isSelected == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func equalAvailabilityPreservesManualAndVaultSelectionOrigin() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["manual", "vault-only"])
        let manualGeneration = try await fixture.repository.selectItemManually(
            itemID: "manual", vaultID: "vault", shareID: "share"
        )
        let vaultSelection = try #require(try await fixture.repository.setVaultSelected(true, vaultID: "vault"))
        _ = try #require(try await fixture.repository.beginRequest(
            itemID: "manual", vaultID: "vault", shareID: "share", kind: .materialization,
            expectations: .init(selectionGeneration: manualGeneration, metadataModifyTime: nil, itemType: nil)
        ))
        _ = try #require(try await fixture.repository.beginRequest(
            itemID: "vault-only", vaultID: "vault", shareID: "share",
            kind: .vaultSelection(policyGeneration: vaultSelection.generation),
            expectations: .init(selectionGeneration: nil, metadataModifyTime: nil, itemType: nil)
        ))

        let projection = try await fixture.database.reader.read { db in
            try OfflineCatalogObservation.presentation(in: db)
        }

        #expect(projection.policyByItemID["manual"]?.isManuallySelected == true)
        #expect(projection.policyByItemID["vault-only"]?.isManuallySelected == false)
        #expect(projection.availabilityByItemID["manual"] == projection.availabilityByItemID["vault-only"])
        #expect(projection.policyByItemID["manual"]?.vaultSelection?.generation == vaultSelection.generation)
        #expect(projection.selectedVaultIDs == ["vault"])
    }

    @Test(.timeLimit(.minutes(1)))
    func pendingManualReservationIsProjectedWithoutCountingUsableCopy() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let generation = try await fixture.repository.selectItemManually(itemID: "item", vaultID: "vault", shareID: "share")
        _ = try #require(try await fixture.repository.beginRequest(
            itemID: "item", vaultID: "vault", shareID: "share", kind: .materialization,
            expectations: .init(selectionGeneration: generation, metadataModifyTime: nil, itemType: nil)
        ))

        let projection = try await fixture.database.reader.read { db in
            try OfflineCatalogObservation.presentation(in: db)
        }

        #expect(projection.selectedVaultIDs.isEmpty)
        #expect(projection.policyByItemID["item"]?.isManuallySelected == true)
        #expect(projection.availabilityByItemID["item"] == .notCached)
        #expect(projection.itemGroups.isEmpty)
        #expect(projection.vaults.first?.selectedCount == 0)
        #expect(projection.vaults.first?.usableCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func usableCountChangesOnlyAfterEncryptedSnapshotPublication() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let gate = OfflineTestGate()
        let viewer = OfflineFixtureViewer(beforeView: { try await gate.wait() })
        let service = fixture.service(viewer: viewer)
        try await initializeOfflineFixtureService(service)
        let observation = OfflineCatalogObservation(database: fixture.database)
        var iterator = observation.snapshots().makeAsyncIterator()
        let initial = try #require(try await iterator.next())
        #expect(initial.vaults.first?.usableCount == 0)

        let item = try #require(fixture.items.first)
        let selection = Task { try await service.makeAvailableOffline(item: item, shareId: "share") }
        try await gate.waitUntilEntered()
        let pending = try #require(try await iterator.next())
        #expect(pending.policyByItemID[item.id]?.isManuallySelected == true)
        #expect(pending.vaults.first?.usableCount == 0)

        await gate.open()
        try await selection.value
        var published: OfflinePresentationSnapshot?
        while let next = try await iterator.next() {
            if next.vaults.first?.usableCount == 1 {
                published = next
                break
            }
        }
        #expect(try #require(published).availabilityByItemID[item.id] != .notCached)
    }
}
