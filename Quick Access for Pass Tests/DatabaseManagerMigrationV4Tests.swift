import Testing
import Foundation
import GRDB
@testable import Quick_Access_for_Pass

@Suite("DatabaseManager v4 migration")
struct DatabaseManagerMigrationV4Tests {

    @Test("items table has fieldKeysJSON column after migration")
    func hasColumn() throws {
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let columns = try db.reader.read { db in
            try db.columns(in: "items").map(\.name)
        }
        #expect(columns.contains("fieldKeysJSON"))
    }

    @Test("new items default to an empty fieldKeys list")
    func newItemsDefault() throws {
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try db.upsertVaults([PassVault(id: "s1", name: "Personal")])
        let item = PassItem(
            id: "i1", vaultId: "s1",
            title: "GitHub", itemType: .login, subtitle: "u",
            url: nil, hasTOTP: false, state: "Active",
            createTime: Date(), modifyTime: Date(),
            useCount: 0, lastUsedAt: nil
        )
        try db.upsertItems([item])
        let fetched = try db.allActiveItems()
        #expect(fetched.count == 1)
        let only = try #require(fetched.first)
        #expect(only.fieldKeys.isEmpty)
    }

    @Test("round-trips a populated fieldKeys list through the DB")
    func roundtripPopulated() throws {
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try db.upsertVaults([PassVault(id: "s1", name: "Personal")])
        let keys: [FieldKey] = [.cardholderName, .cardCVV, .extra(path: .topLevel(fieldIndex: 0), name: "Memo", isSensitive: false)]
        let item = PassItem(
            id: "i2", vaultId: "s1",
            title: "Visa", itemType: .creditCard, subtitle: "John",
            url: nil, hasTOTP: false, state: "Active",
            createTime: Date(), modifyTime: Date(),
            useCount: 0, lastUsedAt: nil,
            fieldKeys: keys
        )
        try db.upsertItems([item])
        let fetched = try #require(try db.allActiveItems().first { $0.id == "i2" })
        #expect(fetched.fieldKeys == keys)
    }

    @Test("malformed fieldKeysJSON falls back to empty without throwing")
    func malformedFieldKeysJSONFallback() throws {
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try db.upsertVaults([PassVault(id: "s1", name: "Personal")])
        try db.writer.write { gdb in
            try gdb.execute(
                sql: """
                INSERT INTO items
                (id, vaultId, title, itemType, subtitle, url, hasTOTP, state,
                 createTime, modifyTime, useCount, lastUsedAt, fieldKeysJSON)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "i-bad", "s1", "Corrupt", "login", "", nil, false, "Active",
                    Date(), Date(), 0, nil, "{not json}",
                ]
            )
        }
        let fetched = try db.allActiveItems()
        let only = try #require(fetched.first(where: { $0.id == "i-bad" }))
        #expect(only.fieldKeys.isEmpty)
    }
}
