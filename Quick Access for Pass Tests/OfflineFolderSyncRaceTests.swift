import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Folder sync capture ownership races", .timeLimit(.minutes(1)))
@MainActor
struct OfflineFolderSyncRaceTests {
    @Test("Reset joins folder preparation/publication before metadata clear and cannot restore its policy", arguments: [false, true])
    func resetDuringWork(publication: Bool) async throws {
        let fixture = try await OfflineFolderSyncFixture.make()
        let resetIdentity = IncrementalSyncGate()
        let resetList = IncrementalSyncGate()
        let reset: @MainActor () async throws -> Void = {
            await fixture.identityBarrier.holdNext(resetIdentity)
            await fixture.runner.holdNextList(resetList)
            fixture.coordinator.resetAndSync()
        }
        if publication { try await fixture.sync(whilePublicationHeld: reset) }
        else { try await fixture.sync(preparing: ["new"], whilePreparationHeld: reset) }
        await resetIdentity.waitUntilEntered()
        let folderCount = try? await fixture.scalar("SELECT COUNT(*) FROM offlineFolders")
        let itemCount = try? await fixture.scalar("SELECT COUNT(*) FROM items")
        await resetIdentity.open()
        await resetList.waitUntilEntered()
        await resetList.open()
        await fixture.coordinator.currentSyncCompletion?.value
        #expect(folderCount == 0)
        #expect(itemCount == 0)
        #expect(try await fixture.snapshot() == nil)
        #expect(try await fixture.scalar("SELECT COUNT(*) FROM offlineSyncCaptures") == 0)
        await fixture.finish()
    }

    @Test("Preparation and queued publication revalidate removal, hierarchy, support and purge", arguments: [false, true], ["remove", "reselect", "parent", "item", "cli", "purge"])
    func queuedRevocation(publication: Bool, change: String) async throws {
        let fixture = try await OfflineFolderSyncFixture.make()
        let mutate: @MainActor () async throws -> Void = {
            switch change {
            case "remove", "reselect":
                try await fixture.service.selectFolder(false, folderID: "parent", vaultID: "vault", featureStamp: nil)
                if change == "reselect" { _ = try await fixture.folder.select("parent") }
            case "parent": try await fixture.replaceCatalog(childParent: "other")
            case "item": try await fixture.replaceCatalog(memberships: ["item": .folder("child"), "new": .folder("other")])
            case "cli": fixture.cli.updateCLIPath("/fake/replaced-during-preparation")
            default: try await fixture.service.removeAllOfflineData()
            }
        }
        if publication { try await fixture.sync(whilePublicationHeld: mutate) }
        else { try await fixture.sync(preparing: ["new"], whilePreparationHeld: mutate) }
        #expect(try await fixture.snapshot() == nil)
        #expect(try await fixture.scalar("SELECT COUNT(*) FROM offlineSyncCaptures") == 0)
        #expect(await fixture.runner.views().isEmpty)
        await fixture.finish()
    }

    @Test("Completed newer explicit Retry wins over the old selected sync generation", arguments: [false, true])
    func newerRetry(publication: Bool) async throws {
        let fixture = try await OfflineFolderSyncFixture.make()
        try await fixture.sync()
        _ = try #require(try await fixture.snapshot("item"))
        await fixture.runner.setSourceTime("1970-01-01T00:00:03Z")
        await fixture.runner.setPassword("sync-value")
        let retry: @MainActor () async throws -> Void = { () async throws -> Void in
            await fixture.codec.setGate(nil)
            await fixture.runner.setPassword("retry-value")
            #expect(try await fixture.service.retryOfflineItem(itemID: "item", vaultID: "vault") == .submitted)
            await fixture.service.waitUntilIdle()
        }
        if publication { try await fixture.sync(whilePublicationHeld: retry) }
        else { try await fixture.sync(preparing: ["item"], whilePreparationHeld: retry) }
        let snapshot = try #require(try await fixture.snapshot("item"))
        let item = try await fixture.codec.base.decodeSnapshot(snapshot)
        guard case .login(let login) = item.content.content else { throw AutoFillSecretResolverError.itemIsNotLogin }
        #expect(login.password == "retry-value")
        #expect(try await fixture.scalar("SELECT COUNT(*) FROM offlineSyncCaptures") == 0)
        await fixture.finish()
    }

    @Test("Removed or reselected policies cannot reuse a captured list", arguments: [false, true])
    func removedOrReselected(reselect: Bool) async throws {
        let fixture = try await OfflineFolderSyncFixture.make()
        try await fixture.sync(whileMetadataHeld: {
            try await fixture.service.selectFolder(false, folderID: "parent", vaultID: "vault", featureStamp: nil)
            if reselect { _ = try await fixture.folder.select("parent") }
            #expect(try await fixture.scalar("SELECT COUNT(*) FROM offlineSyncCaptureFolders") == 1)
        })
        #expect(try await fixture.snapshot() == nil)
        #expect(await fixture.keys.callCount() == 0)
        if reselect {
            try await fixture.sync()
            #expect(try await fixture.snapshot() != nil)
        }
        await fixture.finish()
    }

    @Test("CLI replacement during list fetch cannot publish folder membership")
    func cliGenerationReplacement() async throws {
        let fixture = try await OfflineFolderSyncFixture.make()
        try await fixture.sync(whileListHeld: { fixture.cli.updateCLIPath("/fake/replacement") })
        #expect(try await fixture.snapshot() == nil)
        #expect(await fixture.keys.callCount() == 0)
        #expect(await fixture.runner.views().isEmpty)
        await fixture.finish()
    }

    @Test("Readiness arriving mid-fetch cannot retroactively capture folder consent")
    func readinessDuringFetch() async throws {
        let fixture = try await OfflineFolderSyncFixture.make(initialized: false)
        try await fixture.sync(whileListHeld: { try await initializeOfflineFixtureService(fixture.service) })
        #expect(try await fixture.snapshot() == nil)
        #expect(await fixture.keys.callCount() == 0)
        try await fixture.sync()
        #expect(try await fixture.snapshot() != nil)
        await fixture.finish()
    }

    @Test("Purge while a noncancellable list is held prevents resurrection")
    func purgeDuringFetch() async throws {
        let fixture = try await OfflineFolderSyncFixture.make()
        try await fixture.sync(whileListHeld: { try await fixture.service.removeAllOfflineData() })
        #expect(try await fixture.snapshot() == nil)
        #expect(try await fixture.scalar("SELECT COUNT(*) FROM offlineFolders") == 0)
        #expect(try await fixture.scalar("SELECT COUNT(*) FROM offlineSyncCaptures") == 0)
        #expect(await fixture.keys.callCount() == 0)
        await fixture.finish()
    }
}
