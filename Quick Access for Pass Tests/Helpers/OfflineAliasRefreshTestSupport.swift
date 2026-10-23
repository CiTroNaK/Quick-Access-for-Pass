import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

nonisolated func offlineAliasCLIItem(id: String = "alias", vaultID: String = "vault", shareID: String = "share",
                                    email: String? = nil, modifyTime: String = "1970-01-01T00:00:02Z") throws -> CLIItem {
    let object: [String: Any] = [
        "id": id, "vault_id": vaultID, "share_id": shareID,
        "alias_email": email.map { $0 as Any } ?? NSNull(),
        "content": ["title": "Synthetic alias", "note": "", "item_uuid": id,
                    "content": ["Alias": NSNull()], "extra_fields": []],
        "state": "Active", "flags": [], "create_time": "1970-01-01T00:00:01Z", "modify_time": modifyTime
    ]
    return try JSONDecoder().decode(CLIItem.self, from: JSONSerialization.data(withJSONObject: object))
}

nonisolated extension IncrementalOfflineSyncFixture {
    func seedLegacyAliases() async throws {
        try await initialize()
        try await select()
        try await sync(itemIDs.map { try offlineAliasCLIItem(id: $0) })
        for id in itemIDs { #expect(try await aliasMarker(id) == 0) }
    }
    func aliasMarker(_ id: String = "alias") async throws -> Int? {
        try await database.reader.read { try Int.fetchOne($0, sql: "SELECT contentRevision FROM offlineSnapshots WHERE itemId = ?", arguments: [id]) }
    }
    func aliasRequestGeneration(_ id: String = "alias") async throws -> String? {
        try await database.reader.read { try String.fetchOne($0, sql: "SELECT requestGeneration FROM offlineItems WHERE itemId = ?", arguments: [id]) }
    }
    func aliasTime(_ id: String = "alias") async throws -> Date? {
        try await repository.offlineItemSelection(itemId: id)?.lastRefreshedAt
    }
    func aliasWork(_ items: [CLIItem], provenance: CLISnapshotContentProvenance = .completeJSONV1) async throws
        -> (OfflineSyncCapture, CLISyncFetchResult, MetadataSynchronizationResult) {
        let operation = database.beginSyncOperation()
        let capture = try #require(await service.captureForSync(operation: operation))
        let result = try result(items, provenance: provenance)
        let metadata = try await commit(result, operation: operation)
        return (capture, result, metadata)
    }
    func consumeAlias(_ work: (OfflineSyncCapture, CLISyncFetchResult, MetadataSynchronizationResult)) async throws {
        do {
            try await service.consumeSyncResult(work.1, capture: work.0, metadataProofs: work.2.offlineMetadataProofs, allowMembershipExpansion: true)
            await service.finishSyncCapture(work.0)
        } catch {
            await service.finishSyncCapture(work.0)
            throw error
        }
    }
}
