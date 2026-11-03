import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Incremental folder snapshot synchronization", .timeLimit(.minutes(1)))
@MainActor
struct OfflineFolderSyncTests {
    @Test("A cold supported coordinator captures policies before fetching and caches descendants", arguments: ["2.5.0", "2.5.1"])
    func coldSupportedSync(cliVersion: String) async throws {
        let fixture = try await OfflineFolderSyncFixture.make()
        await fixture.runner.setVersion(cliVersion)
        fixture.cli.folderFeatureGate.invalidateSelection()
        try await fixture.sync(whileListHeld: { () async throws -> Void in
            #expect(fixture.cli.folderFeatureGate.supportedStamp() != nil)
            #expect(try await fixture.scalar("SELECT COUNT(*) FROM offlineSyncCaptureFolders") == 1)
        })
        #expect(fixture.viewModel.syncError == nil)
        #expect(try await fixture.snapshot() != nil)
        #expect(try await fixture.snapshot("item") != nil)
        let views = await fixture.runner.views()
        if cliVersion == "2.5.1" { #expect(views.isEmpty) }
        // Unlisted 2.5.0: one agreeing item view per vault, then the list body is reused.
        else { #expect(views.compactMap { $0.last?.split(separator: "/").last.map(String.init) } == ["item"]) }
        #expect(await fixture.codec.counts().peak == 1)
        #expect(try await fixture.scalar("SELECT COUNT(*) FROM offlineSyncCaptures") == 0)
        await fixture.finish()
    }

    @Test("Selecting a folder during list fetch cannot retroactively reuse its content")
    func noRetroactiveSelection() async throws {
        let fixture = try await OfflineFolderSyncFixture.make(selectParent: false)
        try await fixture.sync(whileMetadataHeld: { _ = try await fixture.folder.select("parent") })
        #expect(try await fixture.snapshot() == nil)
        #expect(await fixture.keys.callCount() == 0)
        try await fixture.sync()
        #expect(try await fixture.snapshot() != nil)
        #expect(await fixture.runner.views().isEmpty)
        await fixture.finish()
    }

    @Test("A captured policy covers an existing item moving into its subtree")
    func movedIntoCapturedFolder() async throws {
        let fixture = try await OfflineFolderSyncFixture.make()
        await fixture.runner.setMemberships(["item": .folder("child"), "other-item": .folder("child")])
        try await fixture.sync()
        #expect(try await fixture.snapshot("other-item") != nil)
        #expect(await fixture.runner.views().isEmpty)
        await fixture.finish()
    }

    @Test("A selected folder containing only a skipped item gains no materialized membership")
    func onlySkippedContent() async throws {
        let fixture = try await OfflineFolderSyncFixture.make()
        await fixture.runner.setMemberships(["item": .folder("child")])
        await fixture.runner.setMalformedIDs(["item"])
        try await fixture.sync()
        #expect(fixture.viewModel.syncError == nil)
        #expect(try await fixture.scalar("SELECT COUNT(*) FROM offlineItems") == 0)
        #expect(try await fixture.scalar("SELECT COUNT(*) FROM offlineFolders") == 1)
        #expect(await fixture.keys.callCount() == 0)
        #expect(await fixture.runner.views().isEmpty)
        await fixture.finish()
    }

    @Test("Missing and partial catalog evidence defer expansion and retain usable bytes", arguments: [false, true])
    func incompleteDiscovery(partialItem: Bool) async throws {
        let fixture = try await OfflineFolderSyncFixture.make()
        let selection = try #require(try await fixture.folder.select("parent"))
        try await fixture.folder.cache(selection)
        let before = try #require(try await fixture.snapshot("item"))
        if partialItem { await fixture.runner.setMalformedIDs(["item"]) }
        else { await fixture.runner.failFolderDiscovery(true) }
        try await fixture.sync()
        #expect(fixture.viewModel.syncError == nil)
        #expect(try await fixture.snapshot() == nil)
        #expect(try await fixture.snapshot("item")?.payload == before.payload)
        #expect(await fixture.keys.callCount() == 0)
        #expect(await fixture.runner.views().isEmpty)
        await fixture.finish()
    }

    @Test("Downgrade suppresses folder capture but preserves independent manual/vault work", arguments: ["folder", "manual", "vault"])
    func downgrade(independent: String) async throws {
        let fixture = try await OfflineFolderSyncFixture.make()
        if independent == "manual" {
            _ = try await fixture.folder.repository.selectItemManually(itemID: "item", vaultID: "vault", shareID: "share")
        } else if independent == "vault" {
            _ = try await fixture.folder.repository.setVaultSelected(true, vaultID: "vault")
        }
        await fixture.runner.setVersion("2.4.2")
        try await fixture.sync(whileListHeld: { () async throws -> Void in
            #expect(try await fixture.scalar("SELECT COUNT(*) FROM offlineSyncCaptureFolders") == 0)
        })
        #expect((try await fixture.snapshot("item") != nil) == (independent != "folder"))
        #expect((try await fixture.snapshot() != nil) == (independent == "vault"))
        #expect(await fixture.runner.arguments().contains { $0.starts(with: ["folder", "list"]) } == false)
        #expect(await fixture.runner.views().isEmpty)
        await fixture.finish()
    }

    @Test("Equal source and display-only folder rename add no crypto, keys, or item views")
    func unchangedAndRenamed() async throws {
        let fixture = try await OfflineFolderSyncFixture.make()
        try await fixture.sync()
        let before = try #require(try await fixture.snapshot())
        let keyCalls = await fixture.keys.callCount()
        let cryptoCalls = await fixture.codec.counts().prepared
        await fixture.runner.setParentName("Renamed / exact text")
        try await fixture.sync()
        #expect(try await fixture.snapshot()?.payload == before.payload)
        #expect(await fixture.keys.callCount() == keyCalls)
        #expect(await fixture.codec.counts().prepared == cryptoCalls)
        #expect(await fixture.runner.views().isEmpty)
        await fixture.finish()
    }
}
