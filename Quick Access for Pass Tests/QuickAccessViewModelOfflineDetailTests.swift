import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("QuickAccessViewModel — Offline Detail")
@MainActor
struct QuickAccessViewModelOfflineDetailTests {
    @Test func enabledVaultShowsMakeAvailableOfflineAction() async throws {
        let fixture = try await makeFixture(enabled: true)
        #expect(try fixture.viewModel.rows(for: fixture.item).contains(.offlineAvailability(.notCached)))
    }

    @Test func unselectedVaultStillOffersSelectableManualOfflineSelection() async throws {
        let fixture = try await makeFixture(enabled: false)
        let row = try #require(fixture.viewModel.rows(for: fixture.item).first(where: {
            if case .offlineAvailability = $0 { return true }
            return false
        }))
        #expect(row == .offlineAvailability(.notCached))
        #expect(row.isSelectable)
        #expect(fixture.viewModel.isDetailRowSelectable(row, for: fixture.item))
        fixture.viewModel.detailItem = fixture.item
        let makeIndex = try #require(fixture.viewModel.rows(for: fixture.item).firstIndex(of: row))
        fixture.viewModel.selectedRowIndex = max(0, makeIndex - 1)
        fixture.viewModel.moveRowSelection(by: 1)
        #expect(fixture.viewModel.selectedRowIndex == makeIndex)
    }

    @Test func vaultOnlyCachedItemOffersKeepActionButManualItemDoesNot() async throws {
        let fixture = try await makeFixture(enabled: true)
        let policy = OfflineItemPolicy(
            key: OfflineSnapshotKey(vaultId: "vault", itemId: fixture.item.id, schemaVersion: 1),
            isManuallySelected: false,
            vaultSelection: OfflineVaultSelection(vaultID: "vault", generation: UUID()),
            isExcluded: false
        )
        let settingsItem = OfflineItemSettingsRow(
            itemId: fixture.item.id, vaultId: fixture.item.vaultId, title: fixture.item.title,
            itemType: fixture.item.itemType, status: .cached, lastRefreshedAt: nil,
            hasUsableSnapshot: true, item: fixture.item
        )
        let group = OfflineItemSettingsGroup(vaultId: "vault", vaultName: "Vault", items: [settingsItem])
        fixture.coordinator.apply(OfflinePresentationSnapshot(
            vaults: [], itemGroups: [group], selectedVaultIDs: ["vault"],
            policyByItemID: [fixture.item.id: policy],
            availabilityByItemID: [fixture.item.id: .available(lastRefreshedAt: nil)]
        ))
        let rows = fixture.viewModel.rows(for: fixture.item)
        #expect(rows.contains(.keepOfflineIndividually))
        #expect(rows.contains(.offlineAvailability(.available(lastRefreshedAt: nil))))
        fixture.coordinator.apply(OfflinePresentationSnapshot(
            vaults: [], itemGroups: [group], selectedVaultIDs: ["vault"],
            policyByItemID: [fixture.item.id: policy],
            availabilityByItemID: [fixture.item.id: .unavailable]
        ))
        #expect(!fixture.viewModel.rows(for: fixture.item).contains(.keepOfflineIndividually))
        fixture.coordinator.apply(OfflinePresentationSnapshot(
            vaults: [], itemGroups: [group], selectedVaultIDs: ["vault"],
            policyByItemID: [fixture.item.id: policy],
            availabilityByItemID: [fixture.item.id: .available(lastRefreshedAt: nil)]
        ))
        let keepIndex = try #require(fixture.viewModel.rows(for: fixture.item).firstIndex(of: .keepOfflineIndividually))
        fixture.viewModel.detailItem = fixture.item
        fixture.viewModel.selectedRowIndex = keepIndex
        fixture.viewModel.showSelectedRowInLargeType()
        #expect(fixture.viewModel.inFlightLargeType == nil)

        let manualPolicy = OfflineItemPolicy(
            key: policy.key, isManuallySelected: true,
            vaultSelection: policy.vaultSelection, isExcluded: false
        )
        fixture.coordinator.apply(OfflinePresentationSnapshot(
            vaults: [], itemGroups: [group], selectedVaultIDs: ["vault"],
            policyByItemID: [fixture.item.id: manualPolicy],
            availabilityByItemID: [fixture.item.id: .available(lastRefreshedAt: nil)]
        ))
        #expect(!fixture.viewModel.rows(for: fixture.item).contains(.keepOfflineIndividually))
    }

    @Test func returnOnKeepPromotesMetadataWithoutFetchAndSurvivesVaultDeselection() async throws {
        let base = try OfflineLifecycleFixture(itemIDs: ["item"])
        let item = try #require(base.items.first)
        let viewer = OfflineFixtureViewer()
        let keys = OfflineFixtureKeys()
        let service = OfflineModeService(repository: base.repository, codec: base.codec(keys: keys), cliService: viewer)
        try await initializeOfflineFixtureService(service)
        try await service.selectWholeVault(true, vaultID: "vault")
        await service.waitUntilIdle()
        let snapshotBefore = try #require(try await base.repository.authorizedSnapshot(
            for: OfflineSnapshotKey(vaultId: "vault", itemId: item.id, schemaVersion: OfflineSnapshotLimits.schemaVersion)
        ))
        let callsBefore = await viewer.callCount(itemID: item.id)
        let keyCreationsBefore = await keys.createCount()
        let keyLookupsBefore = await keys.existingLookupCount()
        let projection = try await base.database.reader.read { try OfflineCatalogObservation.presentation(in: $0) }
        let coordinator = OfflineModeCoordinator(
            service: service,
            observation: SingleDetailObservation(snapshot: projection),
            shareIDForVault: { _ in "share" }
        )
        await coordinator.startObservation().value
        let viewModel = QuickAccessViewModel(
            searchService: SearchService(databaseManager: base.database), cliService: PassCLIService(),
            clipboardManager: ClipboardManager(autoClearSeconds: 0), onDismiss: {}, offlineModeCoordinator: coordinator
        )
        viewModel.detailItem = item
        let keepIndex = try #require(viewModel.rows(for: item).firstIndex(of: .keepOfflineIndividually))
        let offlineIndex = try #require(viewModel.rows(for: item).firstIndex(where: {
            if case .offlineAvailability = $0 { return true }
            return false
        }))
        viewModel.selectedRowIndex = offlineIndex
        viewModel.moveRowSelection(by: 1)
        #expect(viewModel.selectedRowIndex == keepIndex)
        viewModel.moveRowSelection(by: -1)
        #expect(viewModel.selectedRowIndex == offlineIndex)
        viewModel.moveRowSelection(by: 1)
        #expect(viewModel.selectedRowIndex == keepIndex)
        viewModel.handleEnter()
        await viewModel.inFlightOfflineOperation?.value
        #expect(try await base.repository.itemPolicy(itemID: item.id, vaultID: "vault")?.isManuallySelected == true)
        #expect(await viewer.callCount(itemID: item.id) == callsBefore)
        #expect(await keys.createCount() == keyCreationsBefore)
        #expect(await keys.existingLookupCount() == keyLookupsBefore)
        try await coordinator.selectWholeVault(false, vaultID: "vault")
        let snapshotAfter = try #require(try await base.repository.authorizedSnapshot(
            for: OfflineSnapshotKey(vaultId: "vault", itemId: item.id, schemaVersion: OfflineSnapshotLimits.schemaVersion)
        ))
        #expect(snapshotAfter.payload == snapshotBefore.payload)
    }

    private func makeFixture(enabled: Bool) async throws -> DetailFixture {
        let base = try OfflineLifecycleFixture(itemIDs: ["item"])
        let item = try #require(base.items.first)
        let service = base.service()
        try await initializeOfflineFixtureService(service)
        let coordinator = OfflineModeCoordinator(
            service: service,
            observation: StaticDetailObservation(),
            shareIDForVault: { _ in "share" }
        )
        coordinator.apply(OfflinePresentationSnapshot(
            vaults: [OfflineVaultSettingsRow(
                id: "vault", vaultName: "Vault", isSelected: enabled,
                selectedCount: 0, usableCount: 0, lastRefreshedAt: nil
            )],
            itemGroups: [],
            selectedVaultIDs: enabled ? ["vault"] : [],
            policyByItemID: [:],
            availabilityByItemID: [:]
        ))
        let viewModel = QuickAccessViewModel(
            searchService: SearchService(databaseManager: base.database), cliService: PassCLIService(),
            clipboardManager: ClipboardManager(autoClearSeconds: 0), onDismiss: {}, offlineModeCoordinator: coordinator
        )
        return DetailFixture(item: item, coordinator: coordinator, viewModel: viewModel)
    }
}

private struct DetailFixture {
    let item: PassItem
    let coordinator: OfflineModeCoordinator
    let viewModel: QuickAccessViewModel
}

private struct SingleDetailObservation: OfflineCatalogObserving {
    let snapshot: OfflinePresentationSnapshot

    func snapshots() -> AsyncThrowingStream<OfflinePresentationSnapshot, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(snapshot)
            continuation.finish()
        }
    }
}

private struct StaticDetailObservation: OfflineCatalogObserving {
    func snapshots() -> AsyncThrowingStream<OfflinePresentationSnapshot, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
