import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("DatabaseManager — Offline Catalog")
struct DatabaseManagerOfflineTests {
    @Test func offlineItemExclusionsCascadeWithItemAndVaultDeletion() throws {
        let db = try makeDatabase()
        let foreignKeys = try db.writer.read { database in
            try Row.fetchAll(database, sql: "PRAGMA foreign_key_list(offlineItemExclusions)")
                .map { (table: $0["table"] as String, onDelete: $0["on_delete"] as String) }
        }
        #expect(foreignKeys.filter { $0.onDelete.uppercased() == "CASCADE" }.map(\.table).sorted() == ["items", "vaults"])
    }

    @Test func selectingAnItemDoesNotSelectItsVault() throws {
        let db = try makeDatabase()
        try db.upsertVaults([PassVault(id: "vault", name: "Offline")])
        try db.upsertItems([makeItem(id: "item", vaultId: "vault")])

        try db.selectManualOfflineItem(itemId: "item", vaultId: "vault")

        #expect(try db.offlineVaultIds().isEmpty)
        #expect(try db.offlineItemSelection(itemId: "item")?.isManuallySelected == true)
    }

    @Test func selectingAnItemRejectsAnotherVaultId() throws {
        let db = try makeDatabase()
        try db.upsertVaults([
            PassVault(id: "vault-a", name: "A"),
            PassVault(id: "vault-b", name: "B")
        ])
        try db.upsertItems([makeItem(id: "item", vaultId: "vault-a")])
        try db.selectWholeOfflineVault("vault-b")

        #expect(throws: OfflineCatalogError.itemVaultMismatch) {
            try db.selectManualOfflineItem(itemId: "item", vaultId: "vault-b")
        }
    }

    @Test func reconcilingMissingOrMovedItemsReturnsTheirSelections() throws {
        let db = try makeDatabase()
        try db.upsertVaults([
            PassVault(id: "vault-a", name: "A"),
            PassVault(id: "vault-b", name: "B")
        ])
        try db.upsertItems([makeItem(id: "item", vaultId: "vault-a")])
        try db.selectWholeOfflineVault("vault-a")
        try db.selectManualOfflineItem(itemId: "item", vaultId: "vault-a")
        let selection = try #require(try db.offlineItemSelection(itemId: "item"))

        #expect(try db.reconcileOfflineSelections(
            validVaultIds: ["vault-a", "vault-b"],
            currentVaultIDByItemID: ["item": "vault-b"]
        ) == [selection])
        #expect(try db.offlineItemSelections().isEmpty)
    }

    @Test func reconcilingMissingItemsReturnsTheirSelections() throws {
        let db = try makeDatabase()
        try db.upsertVaults([PassVault(id: "vault", name: "Offline")])
        try db.upsertItems([makeItem(id: "item", vaultId: "vault")])
        try db.selectWholeOfflineVault("vault")
        try db.selectManualOfflineItem(itemId: "item", vaultId: "vault")
        let selection = try #require(try db.offlineItemSelection(itemId: "item"))

        #expect(try db.reconcileOfflineSelections(
            validVaultIds: ["vault"],
            currentVaultIDByItemID: [:]
        ) == [selection])
        #expect(try db.offlineItemSelections().isEmpty)
    }

    @Test func cacheStatusCanRepresentAnUnavailableSnapshot() throws {
        let db = try makeDatabase()
        let refreshedAt = Date(timeIntervalSince1970: 3)
        try db.upsertVaults([PassVault(id: "vault", name: "Offline")])
        try db.upsertItems([makeItem(id: "item", vaultId: "vault")])
        try db.selectWholeOfflineVault("vault")
        try db.selectManualOfflineItem(itemId: "item", vaultId: "vault")

        try db.updateOfflineCacheStatus(
            itemId: "item",
            status: .unavailable,
            refreshedAt: refreshedAt
        )

        let selection = try #require(try db.offlineItemSelection(itemId: "item"))
        #expect(selection.cacheStatus == .unavailable)
        #expect(selection.lastRefreshedAt == refreshedAt)
    }

    @Test func metadataSynchronizationPreservesCurrentSelectionAndPrunesInactiveSelection() throws {
        let db = try makeDatabase()
        let vault = PassVault(id: "vault", name: "Offline", shareId: "share")
        let item = makeItem(id: "item", vaultId: "vault")
        _ = try db.syncMetadata(vaults: [vault], items: [item], descriptors: [])
        try db.selectWholeOfflineVault("vault")
        try db.selectManualOfflineItem(itemId: "item", vaultId: "vault")

        _ = try db.syncMetadata(
            vaults: [PassVault(id: "vault", name: "Renamed", shareId: "share")],
            items: [makeItem(id: "item", vaultId: "vault")],
            descriptors: []
        )
        #expect(try db.offlineItemSelection(itemId: "item") != nil)

        let inactive = PassItem(
            id: "item", vaultId: "vault", title: "Example", itemType: .login,
            subtitle: "person@example.com", url: nil, hasTOTP: false, state: "Trashed",
            createTime: Date(timeIntervalSince1970: 1), modifyTime: Date(timeIntervalSince1970: 3),
            useCount: 0, lastUsedAt: nil
        )
        _ = try db.syncMetadata(vaults: [vault], items: [inactive], descriptors: [])
        #expect(try db.offlineItemSelection(itemId: "item") == nil)
    }

    @Test func clearMetadataCascadesOfflineCatalogData() async throws {
        let db = try makeDatabase()
        try db.upsertVaults([PassVault(id: "vault", name: "Offline")])
        try db.upsertItems([makeItem(id: "item", vaultId: "vault")])
        try db.selectWholeOfflineVault("vault")
        try db.selectManualOfflineItem(itemId: "item", vaultId: "vault")

        try await db.clearMetadata()

        #expect(try db.allVaults().isEmpty)
        #expect(try db.offlineItemSelections().isEmpty)
    }

    private func makeDatabase() throws -> DatabaseManager {
        try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
    }

    private func makeItem(id: String, vaultId: String) -> PassItem {
        PassItem(
            id: id,
            vaultId: vaultId,
            title: "Example",
            itemType: .login,
            subtitle: "person@example.com",
            url: nil,
            hasTOTP: false,
            state: "Active",
            createTime: Date(timeIntervalSince1970: 1),
            modifyTime: Date(timeIntervalSince1970: 2),
            useCount: 0,
            lastUsedAt: nil
        )
    }
}
