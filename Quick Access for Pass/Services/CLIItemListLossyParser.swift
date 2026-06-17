import Foundation

nonisolated struct SkippedSyncItem: Equatable, Sendable {
    let vaultId: String
    let vaultName: String
    let itemIndex: Int
    let itemId: String?
    let codingPath: String
    let reason: String

    var diagnosticSummary: String {
        let safeItem = itemId.map { " item_id=\($0)" } ?? ""
        return "vault=\(vaultName) index=\(itemIndex)\(safeItem) path=\(codingPath) reason=\(reason)"
    }
}

nonisolated struct CLIItemListParseResult: Sendable {
    let items: [CLIItem]
    let skippedItems: [SkippedSyncItem]
    let totalItemCount: Int
}

nonisolated enum CLIItemListLossyParser {
    static func parse(_ data: Data, vaultId: String, vaultName: String) throws -> CLIItemListParseResult {
        let root = try rootObject(from: data)
        guard let rawItems = root["items"] as? [Any] else {
            throw CLIError.parseError("item list: missing 'items' at <root>")
        }

        var decodedItems: [CLIItem] = []
        var skippedItems: [SkippedSyncItem] = []
        let decoder = JSONDecoder()

        for (index, rawItem) in rawItems.enumerated() {
            do {
                let itemData = try JSONSerialization.data(withJSONObject: rawItem, options: [])
                decodedItems.append(try decoder.decode(CLIItem.self, from: itemData))
            } catch {
                skippedItems.append(SkippedSyncItem(
                    vaultId: vaultId,
                    vaultName: vaultName,
                    itemIndex: index,
                    itemId: itemId(from: rawItem),
                    codingPath: codingPathDescription(from: error, itemIndex: index),
                    reason: PassCLIService.parseErrorDescription(error, context: "item list")
                ))
            }
        }

        return CLIItemListParseResult(
            items: decodedItems,
            skippedItems: skippedItems,
            totalItemCount: rawItems.count
        )
    }

    private static func rootObject(from data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let root = object as? [String: Any] else {
            throw CLIError.parseError("item list: expected object at <root>")
        }
        return root
    }

    private static func itemId(from rawItem: Any) -> String? {
        guard let dictionary = rawItem as? [String: Any] else { return nil }
        return dictionary["id"] as? String
    }

    private static func codingPathDescription(from error: Error, itemIndex: Int) -> String {
        let path: [CodingKey]
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            path = context.codingPath + [key]
        case DecodingError.valueNotFound(_, let context):
            path = context.codingPath
        case DecodingError.typeMismatch(_, let context):
            path = context.codingPath
        case DecodingError.dataCorrupted(let context):
            path = context.codingPath
        default:
            path = []
        }

        let suffix = PassCLIService.codingPathDescription(path)
        return suffix == "<root>" ? "items.Index \(itemIndex)" : "items.Index \(itemIndex).\(suffix)"
    }
}
