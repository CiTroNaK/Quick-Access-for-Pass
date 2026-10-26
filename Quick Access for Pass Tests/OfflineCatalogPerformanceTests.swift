import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("Offline catalog query performance")
struct OfflineCatalogPerformanceTests {
    /// A whole-catalog projection must not issue another SELECT per selected item.
    @Test(arguments: [1, 40, 1300])
    func queryCountDoesNotGrowWithSelectedItems(count: Int) async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: (0..<count).map { "item-\($0)" })
        for item in fixture.items {
            try OfflineCatalogFixtureSupport.selectManualItem(in: fixture.database, itemId: item.id, vaultId: item.vaultId)
        }
        let (projection, selectCount) = try await fixture.database.reader.read { db in
            var selectCount = 0
            db.trace { event in
                if case .statement(let statement) = event,
                   statement.sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("SELECT ") {
                    selectCount += 1
                }
            }
            defer { db.trace(options: []) }
            let projection = try OfflineCatalogObservation.presentation(in: db)
            return (projection, selectCount)
        }

        #expect(projection.itemGroups.first?.items.count == count)
        #expect(selectCount <= 3, "A projection should use a fixed number of SELECTs, observed \(selectCount) for \(count) items")
    }

    @Test(arguments: [1, 40, 1300])
    func folderProjectionAndSearchStaySetBased(count: Int) async throws {
        let fixture = try OfflineFolderFixture()
        let ids = (0..<count).map { "item-\($0)" }
        let folders: [(String, String?, String)] = [("parent", nil, "Parent")] + (0..<count).map { ("leaf-\($0)", "parent", "Leaf \($0)") }
        let memberships = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, CLIFolderMembership.folder("leaf-\($0.offset)")) })
        let catalog = try CLIFolderCatalogParser.parse(FolderCLIContractFixture.folders(folders), vault: FolderCLIContractFixture.vault,
            memberships: memberships, stamp: #require(fixture.gate.supportedStamp()))
        _ = try await fixture.database.synchronizeMetadata(vaults: [PassVault(id: "vault", name: "Vault", shareId: "share")],
            items: ids.map { offlineTestMetadata(id: $0, vaultID: "vault") }, descriptors: [],
            folderCatalogsByVaultID: ["vault": .complete(catalog)], folderFeatureGate: fixture.gate,
            operation: fixture.database.beginSyncOperation())
        _ = try await fixture.select("parent")
        for id in ids { try OfflineCatalogFixtureSupport.selectManualItem(in: fixture.database, itemId: id, vaultId: "vault") }
        let itemIDs = Set(ids)
        let result = try await fixture.database.reader.read { db in
            var reads: [String] = []
            db.trace { event in
                if case .statement(let statement) = event {
                    let sql = statement.sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                    if sql.hasPrefix("SELECT ") || sql.hasPrefix("WITH ") { reads.append(sql) }
                }
            }
            defer { db.trace(options: []) }
            let locations = try DatabaseManager.folderLocations(for: itemIDs, in: db)
            let searchReads = reads
            reads = []
            let snapshot = try OfflineCatalogObservation.presentation(in: db)
            return (locations, searchReads, snapshot, reads)
        }
        #expect(result.0.count == count)
        #expect(result.0[ids[count - 1]]?.path == "Parent / Leaf \(count - 1)")
        #expect(result.1.count == 1)
        #expect(result.1.allSatisfy { !$0.contains("OFFLINESNAPSHOTS") })
        #expect(result.3.count == 3)
        // Snapshot usability may inspect length, but must not project ciphertext values.
        #expect(result.3.filter { $0.contains("ENCRYPTEDPAYLOAD") }.allSatisfy { $0.contains("LENGTH(S.ENCRYPTEDPAYLOAD)") })
        #expect(result.2.folderRowsByVaultID["vault"]?.count == count + 1)
        #expect(result.2.folderRowsByVaultID["vault"]?.first?.selectedCount == count)
        #expect(result.2.folderRowsByVaultID["vault"]?.first?.usableCount == 0)
    }

    /// Joined-row decoding must preserve the existing complete metadata representation.
    @Test(arguments: [false, true])
    func projectionPreservesCompleteItemMetadata(nullableFields: Bool) async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: [])
        let expected = PassItem(
            id: "metadata-item", vaultId: "vault", title: "Distinct title", itemType: .login,
            subtitle: "metadata@example.test", url: nullableFields ? nil : "https://example.test/login",
            hasTOTP: true, state: "Active", createTime: Date(timeIntervalSince1970: 123),
            modifyTime: Date(timeIntervalSince1970: 456), useCount: 17,
            lastUsedAt: nullableFields ? nil : Date(timeIntervalSince1970: 789), fieldKeys: [.email, .noteBody]
        )
        try fixture.database.upsertItems([expected])
        try OfflineCatalogFixtureSupport.selectManualItem(in: fixture.database, itemId: expected.id, vaultId: "vault")
        let projection = try await fixture.database.reader.read { db in
            try OfflineCatalogObservation.presentation(in: db)
        }
        let actual = try #require(projection.itemGroups.first?.items.first?.item)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(actual) == encoder.encode(expected))
        #expect(actual.fieldKeys == [.email, .noteBody])
        #expect(projection.vaults.first?.selectedCount == 1)
        #expect(projection.vaults.first?.usableCount == 0)
    }
}
