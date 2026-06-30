import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("CLI item list lossy parser")
struct CLIItemListLossyParserTests {

    @Test("malformed item is skipped while valid neighbors decode")
    func skipsMalformedItemAndKeepsValidItems() throws {
        let json = """
        {"items":[
          {
            "id":"good-1","share_id":"share","vault_id":"vault",
            "state":"Active","flags":[],"create_time":"","modify_time":"",
            "content":{"title":"Good 1","note":"","item_uuid":"uuid-1","content":{"Note":null},"extra_fields":[]}
          },
          {
            "id":"bad-1","share_id":"share","vault_id":"vault",
            "state":"Active","flags":[],"create_time":"","modify_time":"",
            "content":{"title":"Bad","note":"","item_uuid":"uuid-2","content":{"Login":{"email":123}},"extra_fields":[]}
          },
          {
            "id":"good-2","share_id":"share","vault_id":"vault",
            "state":"Active","flags":[],"create_time":"","modify_time":"",
            "content":{"title":"Good 2","note":"","item_uuid":"uuid-3","content":{"Note":null},"extra_fields":[]}
          }
        ]}
        """

        let result = try CLIItemListLossyParser.parse(
            Data(json.utf8),
            vaultId: "vault",
            vaultName: "Personal",
            shareId: "vault-share"
        )

        #expect(result.items.map(\.id) == ["good-1", "good-2"])
        #expect(result.totalItemCount == 3)
        #expect(result.skippedItems.count == 1)
        let skipped = try #require(result.skippedItems.first)
        #expect(skipped.vaultId == "vault")
        #expect(skipped.vaultName == "Personal")
        #expect(skipped.itemIndex == 1)
        #expect(skipped.itemId == "bad-1")
        #expect(skipped.diagnosticSummary.contains("share_id=share"))
        #expect(skipped.reason.contains("expected String"))
        #expect(skipped.codingPath.contains("items.Index 1"))
    }

    @Test("skipped item summaries do not include raw secret payload")
    func skippedSummaryDoesNotLeakPayload() throws {
        let json = """
        {"items":[{
          "id":"bad-secret","share_id":"share","vault_id":"vault",
          "state":"Active","flags":[],"create_time":"","modify_time":"",
          "content":{"title":"Secret title","note":"password=super-secret","item_uuid":"uuid", "content":{"Login":{"email":123}},"extra_fields":[]}
        }]}
        """

        let result = try CLIItemListLossyParser.parse(
            Data(json.utf8),
            vaultId: "vault",
            vaultName: "Personal",
            shareId: "vault-share"
        )
        let skipped = try #require(result.skippedItems.first)
        let summary = skipped.diagnosticSummary

        #expect(summary.contains("super-secret") == false)
        #expect(summary.contains("Secret title") == false)
        #expect(summary.contains("bad-secret"))
        #expect(summary.contains("expected String"))
    }

    @Test("valid trashed items decode when present in parser input")
    func decodesValidTrashedItemsWhenPresent() throws {
        let json = """
        {"items":[
          {
            "id":"active-1","share_id":"share","vault_id":"vault",
            "state":"Active","flags":[],"create_time":"","modify_time":"",
            "content":{"title":"Active","note":"","item_uuid":"uuid-1","content":{"Note":null},"extra_fields":[]}
          },
          {
            "id":"trashed-1","share_id":"share","vault_id":"vault",
            "state":"Trashed","flags":[],"create_time":"","modify_time":"",
            "content":{"title":"Trashed","note":"","item_uuid":"uuid-2","content":{"Note":null},"extra_fields":[]}
          }
        ]}
        """

        let result = try CLIItemListLossyParser.parse(
            Data(json.utf8),
            vaultId: "vault",
            vaultName: "Personal",
            shareId: "vault-share"
        )

        #expect(result.items.map(\.id) == ["active-1", "trashed-1"])
        #expect(result.items.map(\.state) == ["Active", "Trashed"])
        #expect(result.totalItemCount == 2)
        #expect(result.skippedItems.isEmpty)
    }

    @Test("malformed active items are still reported as skipped")
    func stillReportsMalformedActiveItems() throws {
        let json = """
        {"items":[{
          "id":"bad-active","share_id":"share","vault_id":"vault",
          "state":"Active","flags":[],"create_time":"","modify_time":"",
          "content":{"title":"Bad Active","note":"","item_uuid":"uuid-active","content":{"Login":{"email":123}},"extra_fields":[]}
        }]}
        """

        let result = try CLIItemListLossyParser.parse(
            Data(json.utf8),
            vaultId: "vault",
            vaultName: "Personal",
            shareId: "vault-share"
        )

        #expect(result.items.isEmpty)
        #expect(result.totalItemCount == 1)
        let skipped = try #require(result.skippedItems.first)
        #expect(skipped.itemId == "bad-active")
        #expect(skipped.reason.contains("expected String"))
    }

    @Test("missing state items remain processable for compatibility")
    func missingStateItemsRemainProcessable() throws {
        let json = """
        {"items":[{
          "id":"legacy-active","share_id":"share","vault_id":"vault",
          "flags":[],"create_time":"","modify_time":"",
          "content":{"title":"Legacy Active","note":"","item_uuid":"uuid-legacy","content":{"Note":null},"extra_fields":[]}
        }]}
        """

        let result = try CLIItemListLossyParser.parse(
            Data(json.utf8),
            vaultId: "vault",
            vaultName: "Personal",
            shareId: "vault-share"
        )

        #expect(result.items.map(\.id) == ["legacy-active"])
        #expect(result.items.first?.state == "Active")
        #expect(result.totalItemCount == 1)
        #expect(result.skippedItems.isEmpty)
    }
}
