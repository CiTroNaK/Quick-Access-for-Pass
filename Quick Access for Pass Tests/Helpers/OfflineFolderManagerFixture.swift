import AppKit
import GRDB
import SwiftUI
import Testing
@testable import Quick_Access_for_Pass

/// Real offline services with synthetic catalog presentation. No production catalog writer bypass.
@MainActor
struct OfflineFolderManagerFixture {
    let folders: OfflineFolderFixture
    let viewCallCount: @Sendable (String) async -> Int
    let service: OfflineModeService
    let coordinator: OfflineModeCoordinator

    init(observationFails: Bool = false, beforeView: @escaping @Sendable () async throws -> Void = {}) async throws {
        let viewer = OfflineFolderManagerViewer(beforeView: beforeView)
        let folders = try await OfflineFolderFixture.make()
        let service = OfflineModeService(repository: folders.repository, codec: folders.codec(), cliService: viewer)
        try await service.initialize()
        let snapshot = try await folders.database.reader.read { try OfflineCatalogObservation.presentation(in: $0) }
        self.folders = folders
        viewCallCount = { viewer.callCount(itemID: $0) }
        self.service = service
        coordinator = OfflineModeCoordinator(service: service,
            observation: FolderManagerFixtureObservation(snapshot: snapshot, fails: observationFails),
            shareIDForVault: { _ in "share" }, folderFeatureGate: folders.gate)
        await coordinator.startObservation().value
    }

    func present(_ rows: [OfflineFolderSettingsRow], vaultName: String = "Synthetic vault", vaultID: String = "vault") {
        coordinator.apply(.init(vaults: [.init(id: vaultID, vaultName: vaultName, isSelected: false,
            selectedCount: 0, usableCount: 0, lastRefreshedAt: nil)], itemGroups: [], selectedVaultIDs: [],
            policyByItemID: [:], availabilityByItemID: [:], folderRowsByVaultID: [vaultID: rows],
            folderCatalogStatusByVaultID: [vaultID: .fresh],
            folderCatalogStampsByVaultID: folders.gate.supportedStamp().map { [vaultID: $0] } ?? [:]))
    }

    func present(vaults: [OfflineVaultSettingsRow], rowsByVaultID: [String: [OfflineFolderSettingsRow]]) {
        let statuses = Dictionary(uniqueKeysWithValues: vaults.map { ($0.id, OfflineFolderCatalogStatus.fresh) })
        let stamps = folders.gate.supportedStamp().map { stamp in
            Dictionary(uniqueKeysWithValues: vaults.map { ($0.id, stamp) })
        } ?? [:]
        coordinator.apply(.init(vaults: vaults, itemGroups: [], selectedVaultIDs: [],
            policyByItemID: [:], availabilityByItemID: [:], folderRowsByVaultID: rowsByVaultID,
            folderCatalogStatusByVaultID: statuses, folderCatalogStampsByVaultID: stamps))
    }

    static func rows(count: Int, longNames: Bool = false, selected: Bool = false) -> [OfflineFolderSettingsRow] {
        (0..<count).map { index in
            let name = longNames ? String(repeating: "Osobní / %{not-a-key} — účty ", count: 30) + "\(index)" : "Folder \(index)"
            return .init(vaultID: "vault", folderID: "folder-\(index)", folderName: name,
                location: .init(folderID: "folder-\(index)", ancestorNames: [name]), isSelected: selected,
                coveringAncestorID: nil, selectedCount: 0, usableCount: 0, lastRefreshedAt: nil)
        }
    }

    static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}

private struct FolderManagerFixtureObservation: OfflineCatalogObserving {
    private enum Failure: Error { case synthetic }
    let snapshot: OfflinePresentationSnapshot
    let fails: Bool
    func snapshots() -> AsyncThrowingStream<OfflinePresentationSnapshot, any Error> {
        AsyncThrowingStream {
            $0.yield(snapshot)
            if fails { $0.finish(throwing: Failure.synthetic) }
            else { $0.finish() }
        }
    }
}
