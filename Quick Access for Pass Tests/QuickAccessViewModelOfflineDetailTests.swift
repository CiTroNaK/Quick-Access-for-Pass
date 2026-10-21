import AppKit
import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("QuickAccessViewModel — Offline Detail")
@MainActor
struct QuickAccessViewModelOfflineDetailTests {
    @Test func removedSelectionChoosesNextPreviouslyKnownSelectableRow() {
        var selection = DetailSelectionState(selectedID: "keepOfflineIndividually")
        selection.reconcile(with: [
            DetailRowSelectionEntry(id: "keepOfflineIndividually", isSelectable: true),
            DetailRowSelectionEntry(id: "field:noteBody", isSelectable: true)
        ])
        selection.reconcile(with: [DetailRowSelectionEntry(id: "field:noteBody", isSelectable: true)])
        #expect(selection.selectedID == "field:noteBody")
    }

    @Test func disabledSelectedEntryFallsForwardUsingPriorSelectableHistory() {
        var selection = DetailSelectionState(selectedID: "offline")
        selection.reconcile(with: [
            DetailRowSelectionEntry(id: "offline", isSelectable: true),
            DetailRowSelectionEntry(id: "field", isSelectable: true)
        ])
        selection.reconcile(with: [
            DetailRowSelectionEntry(id: "offline", isSelectable: false),
            DetailRowSelectionEntry(id: "field", isSelectable: true)
        ])
        #expect(selection.selectedID == "field")
    }

    @Test func noSelectableEntriesLeaveNoSelection() {
        var selection = DetailSelectionState()
        selection.reconcile(with: [
            DetailRowSelectionEntry(id: "section:0:Details", isSelectable: false)
        ])
        #expect(selection.selectedID == nil)
    }

    @Test func selectionHistoryUpdatesEvenWhenCurrentIdentitySurvives() {
        var selection = DetailSelectionState(selectedID: "A")
        selection.reconcile(with: [
            DetailRowSelectionEntry(id: "A", isSelectable: true),
            DetailRowSelectionEntry(id: "C", isSelectable: true)
        ])
        selection.reconcile(with: [
            DetailRowSelectionEntry(id: "A", isSelectable: true),
            DetailRowSelectionEntry(id: "B", isSelectable: true),
            DetailRowSelectionEntry(id: "C", isSelectable: true)
        ])
        #expect(selection.selectedID == "A")
        selection.reconcile(with: [
            DetailRowSelectionEntry(id: "B", isSelectable: true),
            DetailRowSelectionEntry(id: "C", isSelectable: true)
        ])
        #expect(selection.selectedID == "B")
    }

    @Test func selectionHistoryUsesReconciledOrderWhenRowsAreInsertedBeforeSelection() {
        var selection = DetailSelectionState(selectedID: "A")
        selection.reconcile(with: [
            DetailRowSelectionEntry(id: "A", isSelectable: true),
            DetailRowSelectionEntry(id: "C", isSelectable: true)
        ])
        selection.reconcile(with: [
            DetailRowSelectionEntry(id: "B", isSelectable: true),
            DetailRowSelectionEntry(id: "A", isSelectable: true),
            DetailRowSelectionEntry(id: "C", isSelectable: true)
        ])
        selection.reconcile(with: [
            DetailRowSelectionEntry(id: "B", isSelectable: true),
            DetailRowSelectionEntry(id: "C", isSelectable: true)
        ])
        #expect(selection.selectedID == "C")
    }

    @Test func invalidRowRequestKeepsRawEffectiveIndexAndReturnSelectionConsistent() async throws {
        let fixture = try await makeFixture(enabled: false)
        var item = fixture.item
        item.fieldKeys = [.sectionHeader(name: "Fields"), .email, .noteBody]
        fixture.viewModel.detailItem = item
        let noteIndex = try #require(fixture.viewModel.rows(for: item).firstIndex(where: {
            if case .field(let key, _, _) = $0 { return key == .noteBody }
            return false
        }))
        fixture.viewModel.selectDetailRow(at: noteIndex)
        let noteID = try #require(fixture.viewModel.selectedDetailRowID)
        let headerIndex = try #require(fixture.viewModel.rows(for: item).firstIndex(where: {
            if case .sectionHeader = $0 { return true }
            return false
        }))
        fixture.viewModel.selectDetailRow(at: headerIndex)
        fixture.viewModel.selectDetailRow(id: "not-a-current-row")

        #expect(fixture.viewModel.selectedDetailRowID == noteID)
        #expect(fixture.viewModel.selectedDetailRow(for: item)?.id == noteID)
        #expect(fixture.viewModel.selectedRowIndex == noteIndex)
        fixture.viewModel.handleEnter()
        await fixture.viewModel.inFlightCopy?.value
        #expect(fixture.clipboardManager.lastCopiedValue == "fixture-note")
    }

    @Test func genuinelyUnselectedDetailHasNoEffectiveRowOrReturnAction() async throws {
        let fixture = try await makeFixture(enabled: false)
        fixture.viewModel.detailItem = fixture.item
        fixture.viewModel.detailSelectionState.select(nil)
        let valueBefore = fixture.clipboardManager.lastCopiedValue

        #expect(fixture.viewModel.selectedDetailRowID == nil)
        #expect(fixture.viewModel.selectedDetailRow(for: fixture.item) == nil)
        #expect(fixture.viewModel.selectedRowIndex == -1)
        fixture.viewModel.handleEnter()
        await fixture.viewModel.inFlightCopy?.value
        #expect(fixture.viewModel.inFlightCopy == nil)
        #expect(fixture.clipboardManager.lastCopiedValue == valueBefore)
    }

    @Test func coordinatorProjectionsSynchronouslyRefreshLatestSelectionOrder() async throws {
        let fixture = try await makeFixture(enabled: true)
        var item = fixture.item
        item.fieldKeys = [.email, .noteBody]
        fixture.viewModel.detailItem = item
        let noteIndex = try #require(fixture.viewModel.rows(for: item).firstIndex(where: {
            if case .field(let key, _, _) = $0 { return key == .noteBody }
            return false
        }))
        fixture.viewModel.selectDetailRow(at: noteIndex)
        let noteID = try #require(fixture.viewModel.selectedDetailRowID)
        let policy = OfflineItemPolicy(
            key: OfflineSnapshotKey(vaultId: "vault", itemId: item.id, schemaVersion: 1),
            isManuallySelected: false,
            vaultSelection: OfflineVaultSelection(vaultID: "vault", generation: UUID()),
            isExcluded: false
        )
        let settingsItem = OfflineItemSettingsRow(
            itemId: item.id, vaultId: item.vaultId, title: item.title,
            itemType: item.itemType, status: .cached, lastRefreshedAt: nil,
            hasUsableSnapshot: true, item: item
        )
        let group = OfflineItemSettingsGroup(vaultId: "vault", vaultName: "Vault", items: [settingsItem])
        let vaultProjection = OfflinePresentationSnapshot(
            vaults: [], itemGroups: [group], selectedVaultIDs: ["vault"],
            policyByItemID: [item.id: policy],
            availabilityByItemID: [item.id: .available(lastRefreshedAt: nil)]
        )
        fixture.coordinator.apply(vaultProjection)
        let insertedEntries = fixture.viewModel.entries(for: item)
        #expect(insertedEntries.contains(where: { $0.id == DetailRow.keepOfflineIndividually.id }))
        #expect(fixture.viewModel.selectedDetailRowID == noteID)
        #expect(fixture.viewModel.detailSelectionState.entries == insertedEntries)

        let manualPolicy = OfflineItemPolicy(
            key: policy.key, isManuallySelected: true,
            vaultSelection: policy.vaultSelection, isExcluded: false
        )
        fixture.coordinator.apply(OfflinePresentationSnapshot(
            vaults: [], itemGroups: [group], selectedVaultIDs: ["vault"],
            policyByItemID: [item.id: manualPolicy],
            availabilityByItemID: [item.id: .available(lastRefreshedAt: nil)]
        ))
        let removedEntries = fixture.viewModel.entries(for: item)
        #expect(!removedEntries.contains(where: { $0.id == DetailRow.keepOfflineIndividually.id }))
        #expect(fixture.viewModel.selectedDetailRowID == noteID)
        #expect(fixture.viewModel.detailSelectionState.entries == removedEntries)
    }

    @Test func semanticDetailSelectionTracksFieldAcrossOfflineRowInsertionAndRemoval() async throws {
        let fixture = try await makeFixture(enabled: true)
        var item = fixture.item
        item.fieldKeys = [.email, .noteBody]
        fixture.viewModel.detailItem = item
        let fieldIndex = try #require(fixture.viewModel.rows(for: item).firstIndex(where: {
            if case .field(let key, _, _) = $0 { return key == .noteBody }
            return false
        }))
        fixture.viewModel.selectedRowIndex = fieldIndex
        let selectedID = fixture.viewModel.rows(for: item)[fieldIndex].id
        let policy = OfflineItemPolicy(
            key: OfflineSnapshotKey(vaultId: "vault", itemId: item.id, schemaVersion: 1),
            isManuallySelected: false,
            vaultSelection: OfflineVaultSelection(vaultID: "vault", generation: UUID()),
            isExcluded: false
        )
        let settingsItem = OfflineItemSettingsRow(
            itemId: item.id, vaultId: item.vaultId, title: item.title,
            itemType: item.itemType, status: .cached, lastRefreshedAt: nil,
            hasUsableSnapshot: true, item: item
        )
        let group = OfflineItemSettingsGroup(vaultId: "vault", vaultName: "Vault", items: [settingsItem])
        let available = OfflinePresentationSnapshot(
            vaults: [], itemGroups: [group], selectedVaultIDs: ["vault"],
            policyByItemID: [item.id: policy],
            availabilityByItemID: [item.id: .available(lastRefreshedAt: nil)]
        )
        let manualPolicy = OfflineItemPolicy(
            key: policy.key, isManuallySelected: true,
            vaultSelection: policy.vaultSelection, isExcluded: false
        )
        let manual = OfflinePresentationSnapshot(
            vaults: [], itemGroups: [group], selectedVaultIDs: ["vault"],
            policyByItemID: [item.id: manualPolicy],
            availabilityByItemID: [item.id: .available(lastRefreshedAt: nil)]
        )
        fixture.coordinator.apply(available)
        #expect(fixture.viewModel.selectedDetailRowID == selectedID)
        fixture.viewModel.handleEnter()
        await fixture.viewModel.inFlightCopy?.value
        #expect(fixture.clipboardManager.lastCopiedValue == "fixture-note")
        #expect(try await fixture.base.repository.itemPolicy(itemID: item.id, vaultID: "vault")?.isManuallySelected == false)
        fixture.coordinator.apply(manual)
        #expect(fixture.viewModel.selectedDetailRowID == selectedID)
        fixture.viewModel.handleEnter()
        await fixture.viewModel.inFlightCopy?.value
        #expect(fixture.clipboardManager.lastCopiedValue == "fixture-note")
        #expect(try await fixture.base.repository.itemPolicy(itemID: item.id, vaultID: "vault")?.isManuallySelected == false)
    }

    @Test func changingDetailItemResetsSelectionForNewRows() async throws {
        let fixture = try await makeFixture(enabled: false)
        var first = fixture.item
        first.fieldKeys = [.email, .noteBody]
        fixture.viewModel.detailItem = first
        let noteIndex = try #require(fixture.viewModel.rows(for: first).firstIndex(where: {
            if case .field(let key, _, _) = $0 { return key == .noteBody }
            return false
        }))
        fixture.viewModel.selectDetailRow(at: noteIndex)
        let noteID = fixture.viewModel.selectedDetailRowID
        var second = offlineTestMetadata(id: "another-item", vaultID: fixture.item.vaultId)
        second.fieldKeys = [.email]
        fixture.viewModel.detailItem = second
        #expect(fixture.viewModel.selectedDetailRowID != noteID)
        #expect(fixture.viewModel.selectedDetailRowID == fixture.viewModel.rows(for: second).first?.id)
    }

    @Test func enabledVaultShowsMakeAvailableOfflineAction() async throws {
        let fixture = try await makeFixture(enabled: true)
        #expect(fixture.viewModel.rows(for: fixture.item).contains(.offlineAvailability(.notCached)))
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
        let keepRow = try #require(fixture.viewModel.rows(for: fixture.item).first(where: { $0 == .keepOfflineIndividually }))
        fixture.viewModel.detailItem = fixture.item
        fixture.viewModel.selectDetailRow(at: try #require(fixture.viewModel.rows(for: fixture.item).firstIndex(of: keepRow)))
        #expect(!fixture.viewModel.isDetailRowSelectable(keepRow, for: fixture.item))
        #expect(fixture.viewModel.selectedDetailRowID != keepRow.id)
        let effectiveRow = try #require(fixture.viewModel.selectedDetailRow(for: fixture.item))
        #expect(fixture.viewModel.selectedDetailRowID == effectiveRow.id)
        #expect(fixture.viewModel.selectedRowIndex == fixture.viewModel.rows(for: fixture.item).firstIndex(where: { $0.id == effectiveRow.id }))

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
            clipboardManager: ClipboardManager(autoClearSeconds: 0, pasteboard: .withUniqueName()), onDismiss: {}, offlineModeCoordinator: coordinator
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
        let clipboardManager = ClipboardManager(autoClearSeconds: 0, pasteboard: .withUniqueName())
        let viewModel = QuickAccessViewModel(
            searchService: SearchService(databaseManager: base.database), cliService: PassCLIService(),
            clipboardManager: clipboardManager, onDismiss: {}, secretResolver: DetailResolver(), offlineModeCoordinator: coordinator
        )
        return DetailFixture(item: item, coordinator: coordinator, viewModel: viewModel, clipboardManager: clipboardManager, base: base)
    }
}

private struct DetailFixture {
    let item: PassItem
    let coordinator: OfflineModeCoordinator
    let viewModel: QuickAccessViewModel
    let clipboardManager: ClipboardManager
    let base: OfflineLifecycleFixture
}

private struct DetailResolver: SecretItemResolving {
    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<CLIItem> {
        ResolvedSecret(value: try offlineTestCLIItem(
            id: itemId, vaultID: vaultId, shareID: shareId, password: "unused",
            email: "fixture@example.test", note: "fixture-note"
        ), offlineCapability: nil)
    }

    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<String> {
        ResolvedSecret(value: "unused", offlineCapability: nil)
    }
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
