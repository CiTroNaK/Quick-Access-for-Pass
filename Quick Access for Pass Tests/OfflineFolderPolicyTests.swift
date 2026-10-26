import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("Recursive offline folder policies")
struct OfflineFolderPolicyTests {
    @Test("Independent manual and whole-vault consent still allows refresh after downgrade", arguments: [false, true])
    func independentlyAuthorizedFetch(manual: Bool) async throws {
        let fixture = try await OfflineFolderFixture.make()
        let parent = try #require(try await fixture.select("parent"))
        try await fixture.cache(parent)
        if manual { try await fixture.repository.keepItemOfflineIndividually(itemID: "item", vaultID: "vault") }
        else { _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault") }
        let viewer = OfflineFixtureViewer()
        let service = try await fixture.service(viewer: viewer)
        fixture.gate.confirm(capabilities: .init(rawVersionString: "2.4.2"), for: fixture.gate.beginProbe())
        #expect(try await service.retryOfflineItem(itemID: "item", vaultID: "vault") == .submitted)
        await service.waitUntilIdle()
        #expect(await viewer.callCount(itemID: "item") == 1)
        #expect(try await fixture.snapshot() != nil)
        await service.stop()
    }

    @Test("A retained unmaterialized folder row cannot bypass fresh-fetch admission")
    func unmaterializedRetainedSelection() async throws {
        let fixture = try await OfflineFolderFixture.make()
        let parent = try #require(try await fixture.select("parent"))
        let request = try #require(try await fixture.repository.beginRequest(itemID: "item", vaultID: "vault", shareID: "share",
            kind: .folderSelection(folderID: "parent", policyGeneration: parent.generation)))
        try await fixture.repository.finishRequest(request, failed: true)
        _ = fixture.gate.beginProbe()
        #expect(try await fixture.repository.beginRequest(itemID: "item", vaultID: "vault", shareID: "share", kind: .materialization,
            expectations: .init(selectionGeneration: request.selectionGeneration)) == nil)
        #expect(try await fixture.repository.workCandidateForSelectedItem(itemID: "item", vaultID: "vault") == nil)
        #expect(try await fixture.snapshot() == nil)
        _ = try await fixture.select("parent", selected: false)
    }

    @Test("Permission gains contain only the newly added coverage, not every item/ancestor pair")
    func boundedPermissionGains() async throws {
        let fixture = try await OfflineFolderFixture.make()
        let parent = try #require(try await fixture.select("parent"))
        let other = try #require(try await fixture.select("other"))
        try await fixture.cache(parent)
        try await fixture.cache(other, itemID: "other-item")
        let source = OfflineAutomaticCoverage.folder(vaultID: "vault", folderID: "parent")
        let gains = try await fixture.database.reader.read { db in
            try OfflineSnapshotRepository.automaticPromotions(in: db, adding: source)
        }
        #expect(Set(gains.keys) == [fixture.key()])
        #expect(gains[fixture.key()]?.coverage == [source])
        let empty = try await fixture.database.reader.read { db in
            try OfflineSnapshotRepository.automaticPromotions(in: db, adding: .folder(vaultID: "vault", folderID: "empty"))
        }
        #expect(empty.isEmpty)
    }

    @Test("A parent covers descendants and an empty folder gains future items")
    func descendantsAndFutureItems() async throws {
        let fixture = try await OfflineFolderFixture.make()
        let parent = try #require(try await fixture.select("parent"))
        let policy = try #require(try await fixture.repository.itemPolicy(itemID: "item", vaultID: "vault"))
        #expect(policy.folderSelections == [parent])
        #expect(!policy.isManuallySelected)
        #expect(policy.vaultSelection == nil)
        try await fixture.cache(parent)
        #expect(try await fixture.snapshot() != nil)
        let empty = try #require(try await fixture.select("empty"))
        var memberships = OfflineFolderFixture.initialMemberships
        memberships["future"] = .folder("empty")
        try await fixture.synchronize(memberships: memberships)
        let work = try await fixture.repository.workCandidates(vaultID: "vault", includeNewSelections: true, refreshExisting: false)
        #expect(work.contains { $0.key.itemId == "future" && $0.intent == .folderMaterialize(folderID: "empty", policyGeneration: empty.generation) })
        try await fixture.cache(empty, itemID: "future")
        #expect(try await fixture.snapshot(itemID: "future") != nil)
        #expect(try await fixture.repository.itemPolicy(itemID: "root-item", vaultID: "vault")?.folderSelections.isEmpty == true)
    }

    @Test("Parent and vault removal preserve explicit child and manual coverage")
    func independentCoverage() async throws {
        let fixture = try await OfflineFolderFixture.make()
        let child = try #require(try await fixture.select("child"))
        try await fixture.cache(child)
        _ = try await fixture.select("parent")
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        _ = try await fixture.select("parent", selected: false)
        _ = try await fixture.repository.setVaultSelected(false, vaultID: "vault")
        #expect(try await fixture.snapshot() != nil)
        #expect(try await fixture.repository.itemPolicy(itemID: "item", vaultID: "vault")?.folderSelections == [child])
        try await fixture.repository.keepItemOfflineIndividually(itemID: "item", vaultID: "vault")
        _ = try await fixture.select("child", selected: false)
        #expect(try await fixture.snapshot() != nil)
        #expect(try await fixture.repository.offlineItemSelections().count == 1)
    }

    @Test("Removal excludes all automatic coverage; explicit subtree re-selection clears exclusions")
    func exclusions() async throws {
        let fixture = try await OfflineFolderFixture.make()
        let parent = try #require(try await fixture.select("parent"))
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        try await fixture.cache(parent)
        try await fixture.repository.removeItem("item")
        try await fixture.repository.removeItem("other-item")
        #expect(try await fixture.snapshot() == nil)
        #expect(try await fixture.repository.itemPolicy(itemID: "item", vaultID: "vault")?.isExcluded == true)
        let work = try await fixture.repository.workCandidates(vaultID: "vault", includeNewSelections: true, refreshExisting: false)
        #expect(!work.contains { $0.key.itemId == "item" })
        let reselected = try #require(try await fixture.select("parent"))
        #expect(reselected.generation != parent.generation)
        #expect(try await fixture.repository.itemPolicy(itemID: "other-item", vaultID: "vault")?.isExcluded == true)
        #expect(try await fixture.repository.itemPolicy(itemID: "item", vaultID: "vault")?.isExcluded == false)
        #expect(try await fixture.repository.beginRequest(itemID: "item", vaultID: "vault", shareID: "share",
            kind: .folderSelection(folderID: "parent", policyGeneration: parent.generation)) == nil)
        try await fixture.cache(reselected)
        try await fixture.repository.removeItem("item")
        try await fixture.cacheManually()
        #expect(try await fixture.repository.itemPolicy(itemID: "item", vaultID: "vault")?.isExcluded == false)
        #expect(try await fixture.snapshot() != nil)
    }

    @Test("Rename retains policy; moving out removes only last-covered snapshots", arguments: [false, true])
    func structuralChanges(independentChild: Bool) async throws {
        let fixture = try await OfflineFolderFixture.make()
        let parent = try #require(try await fixture.select("parent"))
        if independentChild { _ = try await fixture.select("child") }
        try await fixture.cache(parent)
        try await fixture.synchronize(parentName: "Renamed")
        #expect(try await fixture.repository.itemPolicy(itemID: "item", vaultID: "vault")?.folderSelections.contains(parent) == true)
        #expect(try await fixture.snapshot() != nil)
        try await fixture.synchronize(childParent: nil)
        #expect((try await fixture.snapshot() != nil) == independentChild)
        #expect(try await fixture.repository.hasPersistedSnapshots() == independentChild)
    }

    @Test("Authoritative deletion removes only that folder's explicit policy", arguments: [false, true])
    func deletion(independentChild: Bool) async throws {
        let fixture = try await OfflineFolderFixture.make()
        let parent = try #require(try await fixture.select("parent"))
        let child = independentChild ? try await fixture.select("child") : nil
        try await fixture.cache(parent)
        try await fixture.synchronize(childParent: nil, deletingFolders: ["parent"])
        let policy = try #require(try await fixture.repository.itemPolicy(itemID: "item", vaultID: "vault"))
        #expect(policy.folderSelections == child.map { [$0] } ?? [])
        #expect((try await fixture.snapshot() != nil) == independentChild)
    }

    @Test("Direct service additions require current complete folder authority; removal does not", arguments: [false, true])
    func serviceAdmission(deferred: Bool) async throws {
        let fixture = try await OfflineFolderFixture.make()
        let parent = try #require(try await fixture.select("parent"))
        try await fixture.cache(parent)
        let viewer = OfflineFixtureViewer()
        let service = try await fixture.service(viewer: viewer)
        let stamp = try #require(fixture.gate.supportedStamp())
        if deferred { try await fixture.synchronize(failure: true) }
        else { fixture.gate.confirm(capabilities: .init(rawVersionString: "2.4.2"), for: fixture.gate.beginProbe()) }
        await #expect(throws: OfflineModeService.Error.persistenceFailed) {
            try await service.selectFolder(true, folderID: "other", vaultID: "vault", featureStamp: stamp)
        }
        #expect(await viewer.callCount(itemID: "other-item") == 0)
        let before = try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item")
        #expect(try await service.retryOfflineItem(itemID: "item", vaultID: "vault") == .unavailable)
        await service.waitUntilIdle()
        #expect(await viewer.callCount(itemID: "item") == 0)
        #expect(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item") == before)
        #expect(try await fixture.snapshot() != nil)
        try await service.selectFolder(false, folderID: "parent", vaultID: "vault", featureStamp: nil)
        #expect(try await fixture.snapshot() == nil)
        await service.stop()
    }

    @Test("An item move follows current membership, not the retained label")
    func itemMove() async throws {
        let fixture = try await OfflineFolderFixture.make()
        let parent = try #require(try await fixture.select("parent"))
        try await fixture.cache(parent)
        var memberships = OfflineFolderFixture.initialMemberships
        memberships["item"] = .folder("other")
        try await fixture.synchronize(memberships: memberships)
        #expect(try await fixture.snapshot() == nil)
        #expect(try await fixture.repository.hasPersistedSnapshots() == false)
    }

    @Test("Deferred discovery cannot expand policy but retains cached access and removal")
    func deferredAdmission() async throws {
        let fixture = try await OfflineFolderFixture.make()
        var memberships = OfflineFolderFixture.initialMemberships
        memberships["uncached"] = .folder("child")
        try await fixture.synchronize(memberships: memberships)
        let parent = try #require(try await fixture.select("parent"))
        try await fixture.cache(parent)
        try await fixture.synchronize(memberships: memberships, failure: true)
        let work = try await fixture.repository.workCandidates(vaultID: "vault", includeNewSelections: true, refreshExisting: false)
        #expect(!work.contains { $0.key.itemId == "uncached" })
        #expect(try await fixture.repository.beginRequest(itemID: "uncached", vaultID: "vault", shareID: "share",
            kind: .folderSelection(folderID: "parent", policyGeneration: parent.generation)) == nil)
        await #expect(throws: (any Error).self) { _ = try await fixture.select("other") }
        await #expect(throws: (any Error).self) { _ = try await fixture.select("parent") }
        #expect(try await fixture.snapshot() != nil)
        _ = try await fixture.select("parent", selected: false)
        #expect(try await fixture.snapshot() == nil)
    }

    @Test("Checking, unsupported and unknown CLI reject direct additions, never removal", arguments: ["checking", "2.4.2", "unknown"])
    func capabilityAdmission(version: String) async throws {
        let fixture = try await OfflineFolderFixture.make()
        var memberships = OfflineFolderFixture.initialMemberships
        memberships["uncached"] = .folder("child")
        try await fixture.synchronize(memberships: memberships)
        let parent = try #require(try await fixture.select("parent"))
        try await fixture.cache(parent)
        let oldStamp = try #require(fixture.gate.supportedStamp())
        let probe = fixture.gate.beginProbe()
        if version != "checking" { fixture.gate.confirm(capabilities: .init(rawVersionString: version), for: probe) }
        await #expect(throws: (any Error).self) {
            _ = try await fixture.repository.setFolderSelected(true, folderID: "other", vaultID: "vault", featureStamp: oldStamp)
        }
        #expect(try await fixture.repository.beginRequest(itemID: "uncached", vaultID: "vault", shareID: "share",
            kind: .folderSelection(folderID: "parent", policyGeneration: parent.generation)) == nil)
        let work = try await fixture.repository.workCandidates(vaultID: "vault", includeNewSelections: true, refreshExisting: false)
        #expect(!work.contains { $0.key.itemId == "uncached" })
        let selection = try #require(try await fixture.repository.offlineItemSelection(itemId: "item"))
        #expect(try await fixture.repository.beginRequest(itemID: "item", vaultID: "vault", shareID: "share", kind: .refresh,
            expectations: .init(selectionGeneration: selection.selectionGeneration)) == nil)
        let refreshes = try await fixture.repository.workCandidates(vaultID: "vault", includeNewSelections: false, refreshExisting: true)
        #expect(!refreshes.contains { $0.key.itemId == "item" })
        #expect(try await fixture.snapshot() != nil)
        _ = try await fixture.select("parent", selected: false)
        try await fixture.repository.removeItem("item")
        try await fixture.repository.purge()
        #expect(try await fixture.repository.hasPersistedSnapshots() == false)
    }
}
