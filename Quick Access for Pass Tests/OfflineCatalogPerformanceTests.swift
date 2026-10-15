import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("Offline catalog query performance")
struct OfflineCatalogPerformanceTests {
    /// A whole-catalog projection must not issue another SELECT per selected item.
    @Test(arguments: [1, 40])
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
