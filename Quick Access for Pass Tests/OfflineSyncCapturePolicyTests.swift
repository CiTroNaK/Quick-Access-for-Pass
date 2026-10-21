import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("Offline sync captured policy")
struct OfflineSyncCapturePolicyTests {
    @Test func knownEligibleUnmaterializedMemberUsesVaultOwnership() async throws {
        let fixture = try OfflineSyncPlanningFixture()
        let policy = try #require(try await fixture.repository.setVaultSelected(true, vaultID: "vault"))
        let capture = try await fixture.capture()
        let work = try #require(try await fixture.work(for: capture).first)
        guard case .vaultMember(let generation, let known) = work.ownership else {
            Issue.record("Unmaterialized members must not acquire invented selection generations")
            return
        }
        #expect(generation == policy.generation)
        #expect(known)
        #expect(work.metadataProof.metadataGeneration == nil)
        #expect(try await fixture.scalar("SELECT COUNT(*) FROM offlineItems") == 0)
    }

    @Test func genuinelyNewMemberRequiresUnchangedCapturedPolicyAndCompleteSync() async throws {
        let fixture = try OfflineSyncPlanningFixture(itemIDs: [])
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        let capture = try await fixture.capture()
        try fixture.database.upsertItems([offlineTestMetadata(id: "new", vaultID: "vault")])
        let work = try #require(try await fixture.work(for: capture).first)
        guard case .vaultMember(_, let known) = work.ownership else { Issue.record("Expected future-member ownership"); return }
        #expect(!known)
        #expect(try await fixture.work(for: capture, allowMembershipExpansion: false).isEmpty)
        _ = try await fixture.repository.setVaultSelected(false, vaultID: "vault")
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        #expect(try await fixture.work(for: capture).isEmpty)
    }

    @Test func partialSyncDoesNotMaterializeKnownEligibleMemberButCanRefreshManualSelection() async throws {
        let fixture = try OfflineSyncPlanningFixture(itemIDs: ["member", "manual"])
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        _ = try await fixture.repository.selectItemManually(itemID: "manual", vaultID: "vault", shareID: "share")
        let capture = try await fixture.capture()
        let work = try await fixture.work(for: capture, allowMembershipExpansion: false)
        #expect(work.map(\.key.itemId) == ["manual"])
    }

    @Test func knownUnselectedItemCannotBecomeFutureMemberAfterPolicyEnable() async throws {
        let fixture = try OfflineSyncPlanningFixture()
        let capture = try await fixture.capture()
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        #expect(try await fixture.work(for: capture).isEmpty)
    }

    @Test func exclusionEvidenceSurvivesCatalogDeletionAndReappearance() async throws {
        let fixture = try OfflineSyncPlanningFixture()
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        try await fixture.repository.removeItem("item")
        let capture = try await fixture.capture()
        try await fixture.database.writer.write { try $0.execute(sql: "DELETE FROM items WHERE id = 'item'") }
        #expect(try await fixture.scalar("SELECT COUNT(*) FROM offlineSyncCaptureItems WHERE itemID = 'item' AND isExcluded = 1") == 1)
        try fixture.database.upsertItems([offlineTestMetadata(id: "item", vaultID: "vault")])
        #expect(try await fixture.work(for: capture).isEmpty)
    }

    @Test(arguments: [false, true])
    func knownInactiveItemCannotAcquireNewAdmissionWhenItBecomesActive(manual: Bool) async throws {
        let fixture = try OfflineSyncPlanningFixture()
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        if manual { _ = try await fixture.repository.selectItemManually(itemID: "item", vaultID: "vault", shareID: "share") }
        try await fixture.database.writer.write { try $0.execute(sql: "UPDATE items SET state = 'Trashed'") }
        let capture = try await fixture.capture()
        try await fixture.database.writer.write { try $0.execute(sql: "UPDATE items SET state = 'Active'") }
        #expect(try await fixture.work(for: capture).isEmpty)
    }

    @Test func removeAndReselectRejectsCapturedSelectedGeneration() async throws {
        let fixture = try OfflineSyncPlanningFixture()
        _ = try await fixture.repository.selectItemManually(itemID: "item", vaultID: "vault", shareID: "share")
        let capture = try await fixture.capture()
        try await fixture.repository.removeItem("item")
        _ = try await fixture.repository.selectItemManually(itemID: "item", vaultID: "vault", shareID: "share")
        #expect(try await fixture.work(for: capture).isEmpty)
    }

    @Test func retainedManualSelectionSurvivesVaultOffWhileVaultOnlySelectionDoesNot() async throws {
        let fixture = try OfflineSyncPlanningFixture(itemIDs: ["manual", "member"])
        let policy = try #require(try await fixture.repository.setVaultSelected(true, vaultID: "vault"))
        _ = try await fixture.repository.selectItemManually(itemID: "manual", vaultID: "vault", shareID: "share")
        let request = try #require(try await fixture.repository.beginRequest(
            itemID: "member", vaultID: "vault", shareID: "share", kind: .vaultSelection(policyGeneration: policy.generation)
        ))
        try await fixture.repository.finishRequest(request, failed: true)
        let capture = try await fixture.capture()
        _ = try await fixture.repository.setVaultSelected(false, vaultID: "vault")
        let work = try await fixture.work(for: capture)
        #expect(work.map(\.key.itemId) == ["manual"])
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        #expect(try await fixture.work(for: capture).map(\.key.itemId) == ["manual"])
    }

    @Test func newlySelectedRowIsNotAdoptedByCapturedUnmaterializedMember() async throws {
        let fixture = try OfflineSyncPlanningFixture()
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        let capture = try await fixture.capture()
        _ = try await fixture.repository.selectItemManually(itemID: "item", vaultID: "vault", shareID: "share")
        #expect(try await fixture.work(for: capture).isEmpty)
    }

    @Test func knownItemMovedBetweenVaultsDoesNotMasqueradeAsUnknownFutureItem() async throws {
        let fixture = try OfflineSyncPlanningFixture()
        try fixture.database.upsertVaults([PassVault(id: "other", name: "Other", shareId: "other-share")])
        try fixture.database.upsertItems([offlineTestMetadata(id: "item", vaultID: "other")])
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        let capture = try await fixture.capture()
        try fixture.database.upsertItems([offlineTestMetadata(id: "item", vaultID: "vault")])
        #expect(try await fixture.work(for: capture).isEmpty)
    }

    @Test func emptyDescriptorProofStillBindsSourceShareForUnmaterializedMember() async throws {
        let fixture = try OfflineSyncPlanningFixture()
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        let capture = try await fixture.capture()
        let proof = try await fixture.proofs(for: capture)
        try fixture.database.upsertVaults([PassVault(id: "vault", name: "Vault", shareId: "replacement-share")])
        #expect(try await fixture.work(for: capture, proofs: proof).isEmpty)
    }

    @Test func changedDescriptorProjectionCannotBeRelabeledByCurrentGeneration() async throws {
        let fixture = try OfflineSyncPlanningFixture()
        _ = try await fixture.repository.selectItemManually(itemID: "item", vaultID: "vault", shareID: "share")
        let capture = try await fixture.capture()
        let proof = try await fixture.proofs(for: capture)
        try await fixture.database.writer.write { db in
            try AutoFillCredentialDescriptor(id: UUID(), vaultID: "vault", itemID: "item", shareID: "share",
                                             title: "Offline example", username: "person@example.test",
                                             serviceIdentifier: "example.test", hasTOTP: false).insert(db)
        }
        #expect(try await fixture.work(for: capture, proofs: proof).isEmpty)
    }
}
