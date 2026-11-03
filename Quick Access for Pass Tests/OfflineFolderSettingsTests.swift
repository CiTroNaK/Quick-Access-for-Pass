import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("Recursive offline folder settings", .timeLimit(.minutes(1)))
@MainActor
struct OfflineFolderSettingsTests {
    @Test(arguments: [nil, "2.4.2", "2.5.1", "unknown"] as [String?])
    func folderManagementUsesRetainedFolderMetadataNotItemCountsOrCapability(version: String?) async throws {
        let fixture = try await OfflineFolderManagerFixture()
        let vaults = ["vault", "empty", "unknown"].map { id in
            OfflineVaultSettingsRow(id: id, vaultName: "Same literal / %{vault}", isSelected: false,
                selectedCount: 0, usableCount: 0, lastRefreshedAt: nil)
        }
        fixture.present(vaults: vaults, rowsByVaultID: ["vault": OfflineFolderManagerFixture.rows(count: 1, selected: true), "empty": []])
        let probe = fixture.folders.gate.beginProbe()
        if let version { fixture.folders.gate.confirm(capabilities: .init(rawVersionString: version), for: probe) }
        #expect(fixture.coordinator.hasFolders(in: "vault"))
        #expect(!fixture.coordinator.hasFolders(in: "empty"))
        #expect(!fixture.coordinator.hasFolders(in: "unknown"))
        #expect(fixture.coordinator.vaults.filter { fixture.coordinator.hasFolders(in: $0.id) }.map(\.id) == ["vault"])
        #expect(fixture.coordinator.vaults.map(\.id) == ["vault", "empty", "unknown"])
        #expect(!fixture.coordinator.canSelectFolder(folderID: "folder-0", vaultID: "vault"),
                "Retained display metadata must not authorize new folder selection after a reprobe")
        #expect(await fixture.viewCallCount("item") == 0)
        #expect(try await fixture.folders.repository.offlineItemSelections().isEmpty)
        await fixture.service.stop()
    }

    @Test func treeOrderingCollapseAndUnsupportedRemovalRows() async throws {
        let f = try await OfflineFolderFixture.make()
        _ = try await f.select("parent")
        _ = try await f.select("child")
        let snapshot = try await f.database.reader.read { try OfflineCatalogObservation.presentation(in: $0) }
        let rows = try #require(snapshot.folderRowsByVaultID["vault"])
        var tree = OfflineFolderTreeState()
        #expect(tree.visibleRows(rows, availability: .supported).map(\.folderID) == ["empty", "other", "parent", "child"])
        let parent = try #require(rows.first { $0.folderID == "parent" })
        tree.toggleExpansion(parent.id)
        #expect(tree.visibleRows(rows, availability: .supported).map(\.folderID) == ["empty", "other", "parent"])
        // Even a collapsed branch cannot hide explicit removal controls on downgrade.
        #expect(tree.visibleRows(rows, availability: .requiresUpgrade).map(\.folderID) == ["parent", "child"])
        tree.toggleExpansion(parent.id)
        #expect(tree.visibleRows(rows, availability: .supported).last?.depth == 1)
    }

    @Test func emptyFolderAndIndependentChildIntentSurviveAncestorRemoval() async throws {
        let (f, service, coordinator) = try await context()
        try await coordinator.setFolderSelected(true, folderID: "empty", vaultID: "vault")
        try await coordinator.setFolderSelected(true, folderID: "child", vaultID: "vault")
        await service.waitUntilIdle()
        let childBefore = try await f.repository.folderSelection(folderID: "child", vaultID: "vault")
        try await coordinator.setFolderSelected(true, folderID: "parent", vaultID: "vault")
        await service.waitUntilIdle()
        try await reload(coordinator, fixture: f)
        #expect(try await f.repository.folderSelection(folderID: "child", vaultID: "vault") == childBefore)
        let item = try #require(try f.database.allActiveItems().first { $0.id == "item" })
        #expect(coordinator.shouldOfferKeepOfflineIndividually(item.id))
        #expect(coordinator.canKeepOfflineIndividually(item.id))
        #expect(coordinator.folderLocation(for: item.id)?.path == "Parent / Child")
        f.gate.beginProbe()
        #expect(!coordinator.canSelectFolder(folderID: "other", vaultID: "vault"))
        #expect(coordinator.canDeselectFolder(folderID: "parent", vaultID: "vault"))
        try await coordinator.setFolderSelected(false, folderID: "parent", vaultID: "vault")
        #expect(try await f.repository.folderSelection(folderID: "child", vaultID: "vault") == childBefore)
        #expect(try await f.snapshot() != nil)
        try await coordinator.removeAllOfflineData()
        #expect(try await f.repository.hasPersistedSnapshots() == false)
        #expect(try await f.repository.folderSelection(folderID: "empty", vaultID: "vault") == nil)
        await service.stop()
    }

    @Test func inheritedOnlyCannotRevokeAncestorAndRootRemainsIndividual() async throws {
        let (f, service, coordinator) = try await context()
        try await coordinator.setFolderSelected(true, folderID: "parent", vaultID: "vault")
        await service.waitUntilIdle()
        try await reload(coordinator, fixture: f)
        let rows = try #require(coordinator.folderRowsByVaultID["vault"])
        let child = try #require(rows.first { $0.folderID == "child" })
        #expect(OfflineFolderTreeState.isInheritedOnly(child, vaultSelected: false))
        #expect(!coordinator.canDeselectFolder(folderID: "child", vaultID: "vault"))
        await #expect(throws: OfflineModeCoordinator.Error.operationInProgress) {
            try await coordinator.setFolderSelected(false, folderID: "child", vaultID: "vault")
        }
        #expect(try await f.repository.folderSelection(folderID: "parent", vaultID: "vault") != nil)
        f.gate.beginProbe()
        let root = try #require(try f.database.allActiveItems().first { $0.id == "root-item" })
        try await coordinator.makeAvailableOffline(root)
        #expect(try await f.snapshot(itemID: root.id) != nil)
        #expect(coordinator.folderLocation(for: root.id) == nil)
        await service.stop()
    }

    @Test func programmaticExpansionRejectsUnknownAndSupersededDiscovery() async throws {
        let (f, service, coordinator) = try await context()
        let probe = f.gate.beginProbe()
        await #expect(throws: OfflineModeCoordinator.Error.folderSupportUnavailable) {
            try await coordinator.setFolderSelected(true, folderID: "empty", vaultID: "vault")
        }
        f.gate.confirm(capabilities: .init(rawVersionString: "2.5.1"), for: probe)
        // Verified support alone must not reinterpret an old catalog as fresh discovery.
        #expect(!coordinator.canSelectFolder(folderID: "empty", vaultID: "vault"))
        #expect(try await f.repository.folderSelection(folderID: "empty", vaultID: "vault") == nil)
        try await coordinator.removeAllOfflineData()
        await service.stop()
    }

    private func context() async throws -> (OfflineFolderFixture, OfflineModeService, OfflineModeCoordinator) {
        let f = try await OfflineFolderFixture.make()
        let service = try await f.service(viewer: OfflineFixtureViewer())
        let snapshot = try await f.database.reader.read { try OfflineCatalogObservation.presentation(in: $0) }
        let coordinator = OfflineModeCoordinator(service: service, observation: CompletedFolderSettingsObservation(value: snapshot),
            shareIDForVault: { _ in "share" }, folderFeatureGate: f.gate)
        await coordinator.startObservation().value
        return (f, service, coordinator)
    }

    private func reload(_ coordinator: OfflineModeCoordinator, fixture: OfflineFolderFixture) async throws {
        coordinator.apply(try await fixture.database.reader.read { try OfflineCatalogObservation.presentation(in: $0) })
    }
}

/// Read-only test setup inspection; this adds no production policy API or writer.
private extension OfflineSnapshotRepository {
    func folderSelection(folderID: String, vaultID: String) async throws -> OfflineFolderSelection? {
        try await database.reader.read { db in
            guard let raw = try String.fetchOne(db, sql: "SELECT policyGeneration FROM offlineFolders WHERE vaultId = ? AND folderId = ?",
                                                 arguments: [vaultID, folderID]),
                  let generation = UUID(uuidString: raw) else { return nil }
            return OfflineFolderSelection(vaultID: vaultID, folderID: folderID, generation: generation)
        }
    }
}

private struct CompletedFolderSettingsObservation: OfflineCatalogObserving {
    let value: OfflinePresentationSnapshot
    func snapshots() -> AsyncThrowingStream<OfflinePresentationSnapshot, Error> {
        AsyncThrowingStream { $0.yield(value); $0.finish() }
    }
}
