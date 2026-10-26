import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Quick_Access_for_Pass

@Suite("Capability-gated search folder labels", .timeLimit(.minutes(1)))
@MainActor
struct QuickAccessFolderLabelTests {
    @Test func searchKeepsVaultAndAddsNestedFolderLocation() async throws {
        let fixture = try await OfflineFolderSyncFixture.make()
        let model = fixture.viewModel
        model.performSearch(query: "Offline")
        await model.folderLocationsTask?.value
        let item = try #require(model.items.first { $0.id == "item" })
        let location = try #require(model.folderLocation(for: item.id))
        let row = ItemRowView(item: item, isSelected: false, vaultName: "Vault", folderLocation: location,
                              folderFeatureGate: fixture.cli.folderFeatureGate, folderFeatureStamp: model.folderLocationsStamp)
        #expect(row.vaultName == "Vault")
        #expect(row.visibleFolderLocation?.path == "Parent / Child")
        #expect(model.folderLocation(for: "root-item") == nil)
        await fixture.finish()
    }

    @Test("Cached paths alone never display a pill", arguments: ["2.4.2", "", "2.5.1"])
    func unsupportedHidesImmediately(version: String) async throws {
        let fixture = try await OfflineFolderSyncFixture.make()
        let model = fixture.viewModel
        model.performSearch(query: "Offline")
        await model.folderLocationsTask?.value
        let cached = try #require(model.folderLocation(for: "item"))
        let item = try #require(model.items.first { $0.id == "item" })
        let gate = fixture.cli.folderFeatureGate
        let row = ItemRowView(item: item, isSelected: false, vaultName: "Vault", folderLocation: cached,
                              folderFeatureGate: gate, folderFeatureStamp: model.folderLocationsStamp)
        let probe = gate.beginProbe()
        #expect(model.folderPresentationAvailability != .supported)
        #expect(model.folderLocation(for: "item") == nil)
        #expect(row.visibleFolderLocation == nil)
        gate.confirm(capabilities: .init(rawVersionString: version), for: probe)
        #expect(model.folderLocation(for: "item") == nil)
        #expect(row.visibleFolderLocation == nil)
        #expect(ItemRowView(item: item, isSelected: false, vaultName: "Vault", folderLocation: cached).visibleFolderLocation == nil)
        await fixture.finish()
    }

    @Test func renameRefreshesLabelsWithoutChangingResults() async throws {
        let fixture = try await OfflineFolderSyncFixture.make()
        let model = fixture.viewModel
        model.performSearch(query: "Offline")
        await model.folderLocationsTask?.value
        let before = model.items.map(\.id)
        try await fixture.folder.synchronize(parentName: "Renamed")
        model.performSearch(query: "Offline")
        await model.folderLocationsTask?.value
        #expect(model.items.map(\.id) == before)
        #expect(model.folderLocation(for: "item")?.path == "Renamed / Child")
        await fixture.finish()
    }

    @Test("Awaited metadata cannot restore an obsolete query or CLI context", arguments: [false, true])
    func staleContextCannotReappear(changeCLI: Bool) async throws {
        let fixture = try await OfflineFolderSyncFixture.make()
        let barrier = IncrementalSyncGate()
        let database = fixture.folder.database
        let model = QuickAccessViewModel(searchService: SearchService(databaseManager: database), cliService: fixture.cli,
            clipboardManager: ClipboardManager(), onDismiss: {}, folderLocationLoader: { itemIDs in
                await barrier.wait()
                return try database.folderLocations(for: itemIDs)
            })
        model.performSearch(query: "Offline")
        let obsolete = model.folderLocationsTask
        await barrier.waitUntilEntered()
        if changeCLI { fixture.cli.updateCLIPath("/fake/unverified") }
        else {
            model.searchQuery = "root"
            model.performSearch(query: "root")
        }
        await barrier.open()
        await obsolete?.value
        await model.folderLocationsTask?.value
        #expect(model.folderLocation(for: "item") == nil)
        #expect(model.folderLocationsByItemID.isEmpty)
        await fixture.finish()
    }

    @Test(arguments: [170.0, 480.0])
    func longPathsDoNotIncreaseNativeRowHeight(width: Double) throws {
        let gate = FolderCLIContractFixture.gate()
        let item = offlineTestMetadata(id: "item", vaultID: "vault")
        let path = FolderLocationPresentation(folderID: "child", ancestorNames: [String(repeating: "účty / ", count: 100), "Child"])
        let plain = NSHostingView(rootView: ItemRowView(item: item, isSelected: false, vaultName: "Vault").frame(width: CGFloat(width)))
        let labeled = NSHostingView(rootView: ItemRowView(item: item, isSelected: false, vaultName: "Vault", folderLocation: path,
            folderFeatureGate: gate, folderFeatureStamp: try #require(gate.supportedStamp())).frame(width: CGFloat(width)))
        #expect(labeled.fittingSize.height > 0)
        #expect(labeled.fittingSize.height == plain.fittingSize.height)
        #expect(labeled.fittingSize.width == CGFloat(width))
    }

    @Test func longLiteralPathKeepsTheFullPresentationValue() async throws {
        let fixture = try await OfflineFolderSyncFixture.make()
        let name = String(repeating: "účty / %{not-a-key} — ", count: 20)
        try await fixture.folder.synchronize(parentName: name)
        let model = fixture.viewModel
        model.performSearch(query: "Offline")
        await model.folderLocationsTask?.value
        let item = try #require(model.items.first { $0.id == "item" })
        let row = ItemRowView(item: item, isSelected: true, vaultName: "Vault", folderLocation: model.folderLocation(for: "item"),
                              folderFeatureGate: fixture.cli.folderFeatureGate, folderFeatureStamp: model.folderLocationsStamp)
        #expect(row.visibleFolderLocation?.path == name + " / Child")
        await fixture.finish()
    }
}
