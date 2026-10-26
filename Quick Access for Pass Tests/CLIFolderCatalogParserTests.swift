import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Folder CLI catalog parser")
struct CLIFolderCatalogParserTests {
    @Test("public nested fixture retains exact names and item identities")
    func nestedCatalog() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Folders/nested.json")
        let catalog = try CLIFolderCatalogParser.parse(Data(contentsOf: url), vault: FolderCLIContractFixture.vault,
            memberships: ["root-item": .root, "child-item": .folder("child")], stamp: FolderCLIContractFixture.stamp())
        #expect(catalog.folders.map(\.name) == ["Work / Praha", "České 🔐"])
        #expect(catalog.itemMemberships["root-item"] == .root)
        #expect(catalog.itemMemberships["child-item"] == .folder("child"))
        #expect(catalog.ancestors.contains { $0.folderID == "child" && $0.ancestorID == "root" && $0.depth == 1 })
    }

    @Test("empty and root are authoritative only with complete membership evidence")
    func emptyAndRoot() throws {
        let stamp = try FolderCLIContractFixture.stamp()
        let empty = try CLIFolderCatalogParser.parse(Data("[]".utf8), vault: FolderCLIContractFixture.vault,
                                                    memberships: [:], stamp: stamp)
        #expect(empty.folders.isEmpty && empty.itemMemberships.isEmpty)
        let root = try CLIFolderCatalogParser.parse(Data("[]".utf8), vault: FolderCLIContractFixture.vault,
                                                    memberships: ["item": .root], stamp: stamp)
        #expect(root.itemMemberships["item"] == .root)
        #expect(throws: (any Error).self) {
            try CLIFolderCatalogParser.parse(Data("[]".utf8), vault: FolderCLIContractFixture.vault,
                                             memberships: nil, stamp: stamp)
        }
    }

    @Test("invalid catalog evidence never becomes authoritative", arguments: [
        "{}", "{\"folders\":[]}",
        "[{\"id\":\"a\",\"share_id\":\"share\",\"content\":{\"name\":\"a\"}}]",
        "[{\"id\":\"a\",\"share_id\":\"other-share\",\"parent_folder_id\":null,\"content\":{\"name\":\"a\"}}]"
    ])
    func invalidTransport(json: String) throws {
        let stamp = try FolderCLIContractFixture.stamp()
        #expect(throws: (any Error).self) {
            try CLIFolderCatalogParser.parse(Data(json.utf8), vault: FolderCLIContractFixture.vault,
                                             memberships: [:], stamp: stamp)
        }
    }

    @Test("unknown and dangling item membership cannot become coverage")
    func unknownMembership() throws {
        let stamp = try FolderCLIContractFixture.stamp()
        for membership in [CLIFolderMembership.unknown, .folder("missing")] {
            #expect(throws: (any Error).self) {
                try CLIFolderCatalogParser.parse(Data("[]".utf8), vault: FolderCLIContractFixture.vault,
                                                 memberships: ["item": membership], stamp: stamp)
            }
        }
    }

    @Test("omitted or null folder IDs are root in the proven active-item response")
    func rootMembership() throws {
        let values: [Any?] = [nil, NSNull()]
        for value in values {
            let result = try FolderCLIContractFixture.parseItems(FolderCLIContractFixture.itemData(folderValue: value))
            #expect(result.folderMembershipEvidence == ["item": .root])
        }
        let child = try FolderCLIContractFixture.parseItems(FolderCLIContractFixture.itemData(folderValue: "child"))
        #expect(child.folderMembershipEvidence == ["item": .folder("child")])
    }

    @Test("bad membership or reduced response defers folders without dropping ordinary items")
    func incompleteMembership() throws {
        for data in [try FolderCLIContractFixture.itemData(folderValue: 123),
                     try FolderCLIContractFixture.itemData(includeState: false)] {
            let result = try FolderCLIContractFixture.parseItems(data)
            #expect(result.items.count == 1)
            #expect(result.folderMembershipEvidence == nil)
        }
    }

    @Test("skipped identified or unidentified entries defer all folder membership")
    func skippedEvidence() throws {
        for broken in ["{}", "{\"id\":\"broken\"}"] {
            let result = try FolderCLIContractFixture.parseItems(Data("{\"items\":[\(broken)]}".utf8))
            #expect(result.skippedItems.count == 1)
            #expect(result.folderMembershipEvidence == nil)
        }
    }

    @Test("empty vault or share identity cannot produce a validated catalog", arguments: ["vault", "share"])
    func emptyScope(kind: String) throws {
        let vault = CLIVault(name: "Synthetic vault", vaultId: kind == "vault" ? "" : "vault",
                             shareId: kind == "share" ? "" : "share")
        let stamp = try FolderCLIContractFixture.stamp()
        #expect(throws: (any Error).self) {
            try CLIFolderCatalogParser.parse(Data("[]".utf8), vault: vault, memberships: [:], stamp: stamp)
        }
    }

    @Test("folder metadata stays outside the existing encrypted item payload schema")
    func unchangedPayloadSchema() throws {
        let result = try FolderCLIContractFixture.parseItems(FolderCLIContractFixture.itemData(folderValue: "child"))
        let item = try #require(result.items.first)
        let encoded = try JSONEncoder().encode(item)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["folder_id"] == nil)
        #expect(result.folderMembershipEvidence == ["item": .folder("child")])
    }

    @Test("cross-vault item data defers folder authority, not ordinary parsing")
    func crossVaultItem() throws {
        let data = try FolderCLIContractFixture.itemData()
        let replaced = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"vault_id\":\"vault\"", with: "\"vault_id\":\"other\"")
        let result = try FolderCLIContractFixture.parseItems(Data(replaced.utf8))
        #expect(result.items.count == 1)
        #expect(result.folderMembershipEvidence == nil)
    }

    @Test("duplicate item IDs are not complete membership")
    func duplicateItemIDs() throws {
        let data = try FolderCLIContractFixture.itemData()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let items = try #require(object["items"] as? [[String: Any]])
        let duplicated = try JSONSerialization.data(withJSONObject: ["items": items + items])
        #expect(try FolderCLIContractFixture.parseItems(duplicated).folderMembershipEvidence == nil)
    }
}
