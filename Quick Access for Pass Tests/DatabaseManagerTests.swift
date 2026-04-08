import Testing
import Foundation
import GRDB
@testable import Quick_Access_for_Pass

@Suite("DatabaseManager Tests")
struct DatabaseManagerTests {
    func makeTestDB() throws -> DatabaseManager {
        try DatabaseManager(inMemory: true, passphrase: Data("test-passphrase".utf8))
    }

    private func insertDefaultVault(_ db: DatabaseManager) throws {
        try db.upsertVaults([PassVault(id: "s1", name: "Personal")])
    }

    @Test("stores and retrieves vaults")
    func vaultCRUD() throws {
        let db = try makeTestDB()
        let vault = PassVault(id: "s1", name: "Personal")
        try db.upsertVaults([vault])

        let vaults = try db.allVaults()
        #expect(vaults.count == 1)
        #expect(vaults[0].name == "Personal")
    }

    @Test("stores and retrieves items")
    func itemCRUD() throws {
        let db = try makeTestDB()
        try insertDefaultVault(db)
        let item = PassItem(
            id: "i1", vaultId: "s1",
            title: "GitHub", itemType: .login, subtitle: "user@example.com",
            url: "https://github.com", hasTOTP: false, state: "Active",
            createTime: Date(), modifyTime: Date(),
            useCount: 0, lastUsedAt: nil
        )
        try db.upsertItems([item])

        let items = try db.allActiveItems()
        #expect(items.count == 1)
        #expect(items[0].title == "GitHub")
    }

    @Test("upsert updates existing items without resetting usage stats")
    func upsertPreservesUsage() throws {
        let db = try makeTestDB()
        try insertDefaultVault(db)
        let item = PassItem(
            id: "i1", vaultId: "s1",
            title: "GitHub", itemType: .login, subtitle: "user@example.com",
            url: "https://github.com", hasTOTP: false, state: "Active",
            createTime: Date(), modifyTime: Date(),
            useCount: 0, lastUsedAt: nil
        )
        try db.upsertItems([item])
        try db.recordUsage(itemId: "i1")

        let updated = PassItem(
            id: "i1", vaultId: "s1",
            title: "GitHub Updated", itemType: .login, subtitle: "user@example.com",
            url: "https://github.com", hasTOTP: false, state: "Active",
            createTime: Date(), modifyTime: Date(),
            useCount: 0, lastUsedAt: nil
        )
        try db.upsertItems([updated])

        let items = try db.allActiveItems()
        #expect(items[0].title == "GitHub Updated")
        #expect(items[0].useCount == 1)
    }

    @Test("filters out trashed items")
    func activeOnly() throws {
        let db = try makeTestDB()
        try insertDefaultVault(db)
        let active = PassItem(
            id: "i1", vaultId: "s1",
            title: "Active Item", itemType: .login, subtitle: "",
            url: nil, hasTOTP: false, state: "Active",
            createTime: Date(), modifyTime: Date(),
            useCount: 0, lastUsedAt: nil
        )
        let trashed = PassItem(
            id: "i2", vaultId: "s1",
            title: "Trashed Item", itemType: .login, subtitle: "",
            url: nil, hasTOTP: false, state: "Trashed",
            createTime: Date(), modifyTime: Date(),
            useCount: 0, lastUsedAt: nil
        )
        try db.upsertItems([active, trashed])

        let items = try db.allActiveItems()
        #expect(items.count == 1)
        #expect(items[0].title == "Active Item")
    }

    @Test("removes items not in the latest sync")
    func removeStaleItems() throws {
        let db = try makeTestDB()
        try insertDefaultVault(db)
        let old = PassItem(
            id: "old", vaultId: "s1",
            title: "Old Item", itemType: .login, subtitle: "",
            url: nil, hasTOTP: false, state: "Active",
            createTime: Date(), modifyTime: Date(),
            useCount: 0, lastUsedAt: nil
        )
        try db.upsertItems([old])

        let current = PassItem(
            id: "new", vaultId: "s1",
            title: "New Item", itemType: .login, subtitle: "",
            url: nil, hasTOTP: false, state: "Active",
            createTime: Date(), modifyTime: Date(),
            useCount: 0, lastUsedAt: nil
        )
        try db.syncItems([current])

        let items = try db.allActiveItems()
        #expect(items.count == 1)
        #expect(items[0].title == "New Item")
    }

    @Test("recordUsage increments count and sets timestamp")
    func recordUsage() throws {
        let db = try makeTestDB()
        try insertDefaultVault(db)
        let item = PassItem(
            id: "i1", vaultId: "s1",
            title: "Test", itemType: .login, subtitle: "",
            url: nil, hasTOTP: false, state: "Active",
            createTime: Date(), modifyTime: Date(),
            useCount: 0, lastUsedAt: nil
        )
        try db.upsertItems([item])

        try db.recordUsage(itemId: "i1")
        try db.recordUsage(itemId: "i1")

        let items = try db.allActiveItems()
        #expect(items[0].useCount == 2)
        #expect(items[0].lastUsedAt != nil)
    }

    @Test("recordUsage for unknown id does not throw")
    func recordUsageUnknownId() throws {
        let db = try makeTestDB()
        #expect(throws: Never.self) { try db.recordUsage(itemId: "does-not-exist") }
    }

    @Test("upsertItems with empty array does not remove existing items")
    func upsertEmptyArrayPreservesItems() throws {
        let db = try makeTestDB()
        try insertDefaultVault(db)
        let item = PassItem(
            id: "i1", vaultId: "s1",
            title: "Keep Me", itemType: .login, subtitle: "",
            url: nil, hasTOTP: false, state: "Active",
            createTime: Date(), modifyTime: Date(),
            useCount: 0, lastUsedAt: nil
        )
        try db.upsertItems([item])
        try db.upsertItems([])

        let items = try db.allActiveItems()
        #expect(items.count == 1)
    }

    @Test("syncItems with empty array removes all items")
    func syncWithEmptyRemovesAll() throws {
        let db = try makeTestDB()
        try insertDefaultVault(db)
        let item = PassItem(
            id: "i1", vaultId: "s1",
            title: "Gone", itemType: .login, subtitle: "",
            url: nil, hasTOTP: false, state: "Active",
            createTime: Date(), modifyTime: Date(),
            useCount: 0, lastUsedAt: nil
        )
        try db.upsertItems([item])
        try db.syncItems([])

        let items = try db.allActiveItems()
        #expect(items.isEmpty)
    }

    @Test("allActiveItems returns items sorted by usage then recency")
    func sortOrder() throws {
        let db = try makeTestDB()
        try insertDefaultVault(db)
        let now = Date()
        let items = [
            PassItem(id: "a", vaultId: "s1",
                     title: "Low Use", itemType: .login, subtitle: "",
                     url: nil, hasTOTP: false, state: "Active",
                     createTime: Date(), modifyTime: Date(),
                     useCount: 1, lastUsedAt: now.addingTimeInterval(-100)),
            PassItem(id: "b", vaultId: "s1",
                     title: "High Use", itemType: .login, subtitle: "",
                     url: nil, hasTOTP: false, state: "Active",
                     createTime: Date(), modifyTime: Date(),
                     useCount: 10, lastUsedAt: now),
            PassItem(id: "c", vaultId: "s1",
                     title: "No Use", itemType: .login, subtitle: "",
                     url: nil, hasTOTP: false, state: "Active",
                     createTime: Date(), modifyTime: Date(),
                     useCount: 0, lastUsedAt: nil),
        ]
        try db.upsertItems(items)
        let results = try db.allActiveItems()
        #expect(results[0].title == "High Use")
        #expect(results[1].title == "Low Use")
        #expect(results[2].title == "No Use")
    }
}
