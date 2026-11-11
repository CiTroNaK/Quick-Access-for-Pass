import Foundation
import Testing
@testable import Quick_Access_for_Pass

nonisolated enum FolderCLIContractFixture {
    static let vault = CLIVault(name: "Synthetic vault", vaultId: "vault", shareId: "share")

    static func gate() -> FolderFeatureGate {
        let gate = FolderFeatureGate(selection: .custom(path: "/fake/pass"))
        gate.confirm(capabilities: .init(rawVersionString: "2.5.1"), for: gate.beginProbe())
        return gate
    }

    static func stamp() throws -> FolderFeatureStamp { try #require(gate().supportedStamp()) }

    static func folders(_ rows: [(String, String?, String)], shareID: String = "share") throws -> Data {
        try JSONSerialization.data(withJSONObject: rows.map { id, parent, name in
            ["id": id, "share_id": shareID, "parent_folder_id": parent as Any? ?? NSNull(),
             "content": ["name": name]] as [String: Any]
        })
    }

    static func itemData(folderValue: Any? = nil, includeState: Bool = true,
                         shareID: String = "share", vaultID: String = "vault") throws -> Data {
        var item: [String: Any] = ["id": "item", "share_id": shareID, "vault_id": vaultID,
            "content": ["title": "Synthetic note", "content": ["Note": NSNull()]]]
        if includeState { item["state"] = "Active" }
        if let folderValue { item["folder_id"] = folderValue }
        return try JSONSerialization.data(withJSONObject: ["items": [item]])
    }

    static func parseItems(_ data: Data) throws -> CLIItemListParseResult {
        try CLIItemListLossyParser.parse(data, vaultId: "vault", vaultName: "Synthetic vault", shareId: "share")
    }
}
