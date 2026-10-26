import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("Committed folder presentation", .timeLimit(.minutes(1)))
struct FolderLocationPresentationTests {
    @Test func caseInsensitiveNamesHaveStableIDTies() {
        var graph = FolderPresentationGraph()
        let ids = (0..<32).map { String(format: "%02d", $0) }
        for (index, value) in ids.enumerated() {
            let id = FolderPresentationGraph.FolderID(vaultID: "vault", folderID: value)
            graph.nodes[id] = .init(id: id, name: index.isMultiple(of: 2) ? "Same" : "same", parentID: nil,
                                    isSelected: false, policyGeneration: nil)
        }
        #expect(graph.orderedIDs().map(\.folderID) == ids)
    }

    @Test func missingParentsCyclesAndForeignVaultParentsAreOmitted() {
        var graph = FolderPresentationGraph()
        let child = FolderPresentationGraph.FolderID(vaultID: "vault", folderID: "child")
        let foreign = FolderPresentationGraph.FolderID(vaultID: "other-vault", folderID: "missing")
        graph.nodes[child] = .init(id: child, name: "Child", parentID: "missing", isSelected: false, policyGeneration: nil)
        graph.nodes[foreign] = .init(id: foreign, name: "Foreign", parentID: nil, isSelected: false, policyGeneration: nil)
        #expect(graph.location(for: child) == nil)
        let missing = FolderPresentationGraph.FolderID(vaultID: "vault", folderID: "missing")
        graph.nodes[missing] = .init(id: missing, name: "Cycle", parentID: "child", isSelected: false, policyGeneration: nil)
        #expect(graph.location(for: child) == nil)
        #expect(!graph.orderedIDs().contains(child))
    }

    @Test func hierarchyDepthRemainsBounded() {
        var graph = FolderPresentationGraph()
        for index in 0...FolderCatalogLimits.maximumDepth {
            let id = FolderPresentationGraph.FolderID(vaultID: "vault", folderID: String(index))
            graph.nodes[id] = .init(id: id, name: "Name \(index)", parentID: index == 0 ? nil : String(index - 1),
                                    isSelected: false, policyGeneration: nil)
        }
        #expect(graph.location(for: .init(vaultID: "vault", folderID: "63"))?.ancestorNames.count == 64)
        #expect(graph.location(for: .init(vaultID: "vault", folderID: "64")) == nil)
    }

    @Test func nestedRootAndUnresolvedLocations() async throws {
        let fixture = try await OfflineFolderFixture.make()
        let locations = try fixture.database.folderLocations(for: ["item", "other-item", "root-item", "missing"])
        #expect(locations["item"]?.folderID == "child")
        #expect(locations["item"]?.ancestorNames == ["Parent", "Child"])
        #expect(locations["item"]?.path == "Parent / Child")
        #expect(locations["other-item"]?.path == "Other")
        #expect(locations["root-item"] == nil)
        #expect(locations["missing"] == nil)
        try await fixture.synchronize(memberships: ["item": .folder("child"), "root-item": .root, "unresolved": .unknown], failure: true)
        #expect(try fixture.database.folderLocations(for: ["unresolved"])["unresolved"] == nil)
        #expect(try fixture.database.folderLocations(for: ["item"])["item"]?.path == "Parent / Child")
    }

    @Test func namesAreVerbatimAndNeverIdentity() async throws {
        let fixture = try await OfflineFolderFixture.make()
        let literal = "Child / Czech: účty — %{value}"
        try await fixture.synchronize(parentName: literal)
        let location = try #require(try fixture.database.folderLocations(for: ["item"])["item"])
        #expect(location.folderID == "child")
        #expect(location.ancestorNames == [literal, "Child"])
        #expect(location.path == literal + " / Child")
        try await fixture.synchronize(parentName: "Child")
        #expect(try fixture.database.folderLocations(for: ["item"])["item"]?.ancestorNames == ["Child", "Child"])
    }

    @Test func authoritativeRenameAndMoveChangeOnlyPresentation() async throws {
        let fixture = try await OfflineFolderFixture.make()
        try await fixture.synchronize(parentName: "Renamed")
        #expect(try fixture.database.folderLocations(for: ["item"])["item"]?.path == "Renamed / Child")
        try await fixture.synchronize(childParent: "other")
        #expect(try fixture.database.folderLocations(for: ["item"])["item"]?.path == "Other / Child")
    }

    @Test func selectedCountsDoNotMultiplyOverlappingPolicies() async throws {
        let fixture = try await OfflineFolderFixture.make()
        let parent = try #require(try await fixture.select("parent"))
        let child = try #require(try await fixture.select("child"))
        try await fixture.cache(parent)
        try await fixture.cacheManually(itemID: "other-item")
        try await fixture.cacheManually(itemID: "root-item")
        let snapshot = try await fixture.database.reader.read { try OfflineCatalogObservation.presentation(in: $0) }
        let rows = try #require(snapshot.folderRowsByVaultID["vault"])
        let parentRow = try #require(rows.first { $0.folderID == "parent" })
        let childRow = try #require(rows.first { $0.folderID == "child" })
        #expect(parentRow.isSelected)
        #expect(childRow.isSelected)
        #expect(childRow.coveringAncestorID == "parent")
        #expect(parentRow.selectedCount == 1 && parentRow.usableCount == 1)
        #expect(childRow.selectedCount == 1 && childRow.usableCount == 1)
        #expect(childRow.depth == 1)
        #expect(childRow.path == "Parent / Child")
        #expect(parentRow.lastRefreshedAt == Date(timeIntervalSince1970: 3))
        #expect(snapshot.vaults.first?.selectedCount == 3)
        #expect(snapshot.policyByItemID["item"]?.folderSelections == [child, parent])
        #expect(snapshot.folderCatalogStatusByVaultID["vault"] == .fresh)
        #expect(OfflineFolderSettingsRow.ID(vaultID: "first", folderID: "same") != OfflineFolderSettingsRow.ID(vaultID: "second", folderID: "same"))
    }

    @Test func provisionalRowsDoNotInflateFolderCounts() async throws {
        let fixture = try await OfflineFolderFixture.make()
        let parent = try #require(try await fixture.select("parent"))
        _ = try #require(try await fixture.repository.beginRequest(itemID: "item", vaultID: "vault", shareID: "share",
            kind: .folderSelection(folderID: "parent", policyGeneration: parent.generation)))
        let snapshot = try await fixture.database.reader.read { try OfflineCatalogObservation.presentation(in: $0) }
        #expect(snapshot.folderRowsByVaultID["vault"]?.first { $0.folderID == "parent" }?.selectedCount == 0)
        #expect(snapshot.folderRowsByVaultID["vault"]?.first { $0.folderID == "parent" }?.usableCount == 0)
        #expect(snapshot.policyByItemID["item"]?.folderSelections == [parent])
        #expect(snapshot.itemGroups.isEmpty)
    }

    @Test func folderNamesDoNotExpandSearchMatchingOrRanking() async throws {
        let fixture = try await OfflineFolderFixture.make()
        let search = SearchService(databaseManager: fixture.database)
        let before = try search.search(query: "Offline").map(\.id)
        #expect(before.count == 3)
        try await fixture.synchronize(parentName: "UnsearchableFolderOnlyToken")
        #expect(try search.search(query: "UnsearchableFolderOnlyToken").isEmpty)
        #expect(try search.search(query: "Offline").map(\.id) == before)
        #expect(try search.folderLocations(for: ["item"])["item"]?.path == "UnsearchableFolderOnlyToken / Child")
    }
}
