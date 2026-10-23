import Foundation
import Testing
@testable import Quick_Access_for_Pass

nonisolated func offlineTestAliasItem(email: String?, includeEmail: Bool = true, modifyTime: String = "1970-01-01T00:00:02Z") throws -> CLIItem {
    var object: [String: Any] = [
        "id": "item", "vault_id": "vault", "share_id": "share",
        "content": ["title": "Synthetic alias", "note": "", "item_uuid": "uuid",
                    "content": ["Alias": NSNull()], "extra_fields": []],
        "state": "Active", "flags": [], "create_time": "", "modify_time": modifyTime
    ]
    if includeEmail { object["alias_email"] = email.map { $0 as Any } ?? NSNull() }
    return try JSONDecoder().decode(CLIItem.self, from: JSONSerialization.data(withJSONObject: object))
}

nonisolated struct OfflineAliasPublicationFixture: Sendable {
    let planning: OfflineSyncPlanningFixture
    var database: DatabaseManager { planning.database }
    var repository: OfflineSnapshotRepository { planning.repository }

    init() throws {
        planning = try OfflineSyncPlanningFixture()
        try database.upsertItems([Self.metadata()])
    }

    static func metadata(sourceTime: Int = 2) -> PassItem {
        PassItem(
            id: "item", vaultId: "vault", title: "Synthetic alias", itemType: .alias,
            subtitle: "", url: nil, hasTOTP: false, state: "Active",
            createTime: Date(timeIntervalSince1970: 1), modifyTime: Date(timeIntervalSince1970: Double(sourceTime)),
            useCount: 0, lastUsedAt: nil
        )
    }

    func prepare(hasEmail: Bool, sourceTime: Int = 2) async throws -> PreparedOfflineSnapshot {
        let codec = OfflineSnapshotCodec(keyMaterialProvider: OfflineFixtureKeys(), hasPersistedSnapshots: {
            try await repository.hasPersistedSnapshots()
        })
        return try await codec.prepareSnapshot(
            from: offlineTestAliasItem(email: hasEmail ? "synthetic@example.test" : nil,
                                      modifyTime: "1970-01-01T00:00:0\(sourceTime)Z"),
            for: OfflineSnapshotPreparationIdentity(
                key: OfflineSnapshotKey(vaultId: "vault", itemId: "item", schemaVersion: 1),
                shareID: "share", itemType: .alias
            )
        )
    }

    func request() async throws -> OfflineRequestToken {
        try #require(try await repository.beginRequest(itemID: "item", vaultID: "vault", shareID: "share", kind: .selection))
    }

    func seed(hasEmail: Bool = false) async throws -> PreparedOfflineSnapshot {
        let request = try await request()
        let prepared = try await prepare(hasEmail: hasEmail, sourceTime: 1)
        #expect(try await repository.publish(prepared, for: request, refreshedAt: Date(timeIntervalSince1970: 3)))
        return prepared
    }
}
