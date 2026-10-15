import Foundation

nonisolated struct SkippedSyncItem: Equatable, Sendable {
    let vaultId: String
    let vaultName: String
    let shareId: String
    let itemIndex: Int
    let itemId: String?
    let codingPath: String
    let reason: String

    var diagnosticSummary: String {
        let safeItem = itemId.map { " item_id=\($0)" } ?? ""
        return "vault=\(vaultName) share_id=\(shareId) index=\(itemIndex)\(safeItem) path=\(codingPath) reason=\(reason)"
    }

    func inspectCommand(cliSelection: PassCLISelection) -> String {
        let executable = Self.shellEscape(cliSelection.path)
        let shareIdOption = Self.shellOption("--share-id", value: shareId)
        if let itemId, !itemId.isEmpty {
            return "\(executable) item view \(shareIdOption) \(Self.shellOption("--item-id", value: itemId)) --output json"
        }

        return """
        # Item ID was not available. Inspect zero-based index \(itemIndex) in the returned items array.
        \(executable) item list \(shareIdOption) --filter-state=active --output json
        """
    }

    private static func shellOption(_ name: String, value: String) -> String {
        "\(name)=\(shellEscape(value))"
    }

    private static func shellEscape(_ value: String) -> String {
        let safeShellCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        guard value.rangeOfCharacter(from: safeShellCharacters.inverted) != nil else {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

/// Transient, non-secret evidence that a successful vault list was incomplete.
/// Vault identity comes only from the enumerated vault, never a malformed entry.
nonisolated struct SyncItemPresenceUncertainty: Sendable {
    let vaultID: String
    let skippedItemIDs: Set<String>
    let hasUnidentifiedSkippedItems: Bool
}

nonisolated struct CLIItemListParseResult: Sendable {
    let items: [CLIItem]
    let skippedItems: [SkippedSyncItem]
    let totalItemCount: Int
    let presenceUncertainty: SyncItemPresenceUncertainty
    let contentProvenance: CLISnapshotContentProvenance
}

nonisolated enum CLIItemListLossyParser {
    static func parse(
        _ data: Data, vaultId: String, vaultName: String, shareId: String,
        contentProvenance: CLISnapshotContentProvenance = .unavailable
    ) throws -> CLIItemListParseResult {
        let root = try rootObject(from: data)
        guard let rawItems = root["items"] as? [Any] else {
            throw CLIError.parseError("item list: missing 'items' at <root>")
        }

        var decodedItems: [CLIItem] = []
        var skippedItems: [SkippedSyncItem] = []
        var skippedItemIDs: Set<String> = []
        var hasUnidentifiedSkippedItems = false
        let decoder = JSONDecoder()
        var complete = contentProvenance == .completeJSONV1

        for (index, rawItem) in rawItems.enumerated() {
            do {
                let itemData = try JSONSerialization.data(withJSONObject: rawItem, options: [.fragmentsAllowed])
                let item = try decoder.decode(CLIItem.self, from: itemData)
                decodedItems.append(item)
                if complete {
                    complete = item.vaultId == vaultId && item.shareId == shareId
                        && CLISnapshotContentProvenance.validatesShape(rawItem, of: item)
                }
            } catch {
                complete = false
                if let id = itemId(from: rawItem), !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    skippedItemIDs.insert(id)
                } else {
                    hasUnidentifiedSkippedItems = true
                }
                skippedItems.append(SkippedSyncItem(
                    vaultId: vaultId,
                    vaultName: vaultName,
                    shareId: rawShareId(from: rawItem) ?? shareId,
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
            totalItemCount: rawItems.count,
            presenceUncertainty: SyncItemPresenceUncertainty(
                vaultID: vaultId, skippedItemIDs: skippedItemIDs,
                hasUnidentifiedSkippedItems: hasUnidentifiedSkippedItems
            ),
            contentProvenance: complete ? .completeJSONV1 : .unavailable
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

    private static func rawShareId(from rawItem: Any) -> String? {
        guard let dictionary = rawItem as? [String: Any] else { return nil }
        return dictionary["share_id"] as? String
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
