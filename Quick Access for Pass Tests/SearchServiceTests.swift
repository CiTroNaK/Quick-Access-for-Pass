import Testing
import Foundation
import GRDB
@testable import Quick_Access_for_Pass

@Suite("SearchService Tests")
struct SearchServiceTests {
    func makeTestSetup() throws -> (DatabaseManager, SearchService) {
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let search = SearchService(databaseManager: db)
        return (db, search)
    }

    func sampleItems() -> [PassItem] {
        [
            PassItem(id: "1", vaultId: "s1",
                     title: "GitHub", itemType: .login, subtitle: "john@github.com",
                     url: "https://github.com", hasTOTP: false, state: "Active",
                     createTime: Date(), modifyTime: Date(),
                     useCount: 5, lastUsedAt: Date()),
            PassItem(id: "2", vaultId: "s1",
                     title: "GitLab", itemType: .login, subtitle: "john@gitlab.com",
                     url: "https://gitlab.com", hasTOTP: false, state: "Active",
                     createTime: Date(), modifyTime: Date(),
                     useCount: 1, lastUsedAt: nil),
            PassItem(id: "3", vaultId: "s1",
                     title: "AWS Console", itemType: .login, subtitle: "admin@company.com",
                     url: "https://aws.amazon.com", hasTOTP: false, state: "Active",
                     createTime: Date(), modifyTime: Date(),
                     useCount: 10, lastUsedAt: Date()),
            PassItem(id: "4", vaultId: "s1",
                     title: "Visa Card", itemType: .creditCard, subtitle: "John Doe",
                     url: nil, hasTOTP: false, state: "Active",
                     createTime: Date(), modifyTime: Date(),
                     useCount: 0, lastUsedAt: nil),
        ]
    }

    private func insertVaultAndItems(_ db: DatabaseManager) throws {
        try db.upsertVaults([PassVault(id: "s1", name: "Personal")])
        try db.upsertItems(sampleItems())
    }

    @Test("empty query returns all active items sorted by usage")
    func emptyQuery() throws {
        let (db, search) = try makeTestSetup()
        try insertVaultAndItems(db)

        let results = try search.search(query: "")
        #expect(results.count == 4)
        #expect(results[0].title == "AWS Console")
        #expect(results[1].title == "GitHub")
    }

    @Test("search matches title prefix")
    func titlePrefix() throws {
        let (db, search) = try makeTestSetup()
        try insertVaultAndItems(db)

        let results = try search.search(query: "git")
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.title.lowercased().hasPrefix("git") })
    }

    @Test("search matches subtitle")
    func subtitleMatch() throws {
        let (db, search) = try makeTestSetup()
        try insertVaultAndItems(db)

        let results = try search.search(query: "admin")
        #expect(results.count == 1)
        #expect(results[0].title == "AWS Console")
    }

    @Test("search matches URL")
    func urlMatch() throws {
        let (db, search) = try makeTestSetup()
        try insertVaultAndItems(db)

        let results = try search.search(query: "amazon")
        #expect(results.count == 1)
        #expect(results[0].title == "AWS Console")
    }

    @Test("no results for non-matching query")
    func noResults() throws {
        let (db, search) = try makeTestSetup()
        try insertVaultAndItems(db)

        let results = try search.search(query: "nonexistent")
        #expect(results.isEmpty)
    }

    @Test("search is case-insensitive")
    func caseInsensitive() throws {
        let (db, search) = try makeTestSetup()
        try insertVaultAndItems(db)

        let lower = try search.search(query: "github")
        let upper = try search.search(query: "GITHUB")
        let mixed = try search.search(query: "GitHub")
        #expect(lower.count == 1)
        #expect(lower.count == upper.count)
        #expect(lower.count == mixed.count)
    }

    @Test("search handles FTS reserved words and special characters without throwing")
    func specialCharacters() throws {
        let (db, search) = try makeTestSetup()
        try insertVaultAndItems(db)

        // FTS5 reserved keywords must be filtered out — these should not throw
        #expect(throws: Never.self) { try search.search(query: "AND OR NOT") }
        #expect(throws: Never.self) { try search.search(query: "NEAR") }
        // Punctuation stripped by tokenizer — no throw
        #expect(throws: Never.self) { try search.search(query: "\"quoted\"") }
        #expect(throws: Never.self) { try search.search(query: "()") }
        // Pure reserved keywords produce no results (all terms filtered)
        let results = try search.search(query: "AND OR NOT")
        #expect(results.isEmpty)
    }

    @Test("results sorted by usage count descending for empty query")
    func sortedByUsage() throws {
        let (db, search) = try makeTestSetup()
        try insertVaultAndItems(db)

        let results = try search.search(query: "")
        #expect(results.first?.title == "AWS Console") // useCount = 10
    }

    @Test("recordUsage promotes item in results")
    func recordUsagePromotesItem() throws {
        let (db, search) = try makeTestSetup()
        try insertVaultAndItems(db)

        // GitLab starts lower (useCount=1). Record many usages to push it above GitHub (5).
        for _ in 0..<10 {
            try search.recordUsage(itemId: "2")
        }
        let results = try search.search(query: "git")
        #expect(results.first?.title == "GitLab")
    }

    @Test("trashed items excluded from search results")
    func trashedItemsExcluded() throws {
        let (db, search) = try makeTestSetup()
        try db.upsertVaults([PassVault(id: "s1", name: "Personal")])
        let trashedItem = PassItem(
            id: "t1", vaultId: "s1",
            title: "Trashed GitHub", itemType: .login, subtitle: "t@github.com",
            url: nil, hasTOTP: false, state: "Trashed",
            createTime: Date(), modifyTime: Date(),
            useCount: 100, lastUsedAt: nil
        )
        try db.upsertItems(sampleItems() + [trashedItem])

        let results = try search.search(query: "trashed")
        #expect(results.isEmpty)
    }

}
