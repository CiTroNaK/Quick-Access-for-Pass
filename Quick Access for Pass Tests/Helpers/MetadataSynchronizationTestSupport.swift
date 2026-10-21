import Foundation
import GRDB
import Synchronization
@testable import Quick_Access_for_Pass

nonisolated struct MetadataWriteReport: Sendable {
    let updates: [String: Int]
    let selects: Int
    let pointItemLookups: Int
    let selectShapes: [String: Int]
}

/// Counts unexpanded statement shapes and actual row UPDATEs, never values or fetched content.
nonisolated final class MetadataWriteCounter: Sendable {
    private let state = Mutex((selects: 0, points: 0, shapes: [String: Int]()))

    func install(on database: DatabaseManager) throws {
        try database.writer.writeWithoutTransaction { db in
            try db.execute(sql: "CREATE TEMP TABLE metadataUpdates (target TEXT NOT NULL)")
            for table in ["items", "vaults", "autoFillDescriptors", "offlineItems"] {
                // Fixed test-authored identifiers only; no external input or production helper.
                try db.execute(sql: """
                    CREATE TEMP TRIGGER metadataCount_\(table) AFTER UPDATE ON main.\(table)
                    BEGIN INSERT INTO metadataUpdates (target) VALUES ('\(table)'); END
                    """)
            }
            db.trace { event in
                guard case .statement(let statement) = event else { return }
                let sql = statement.sql.replacingOccurrences(of: "\"", with: "").uppercased()
                guard sql.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("SELECT ") else { return }
                self.state.withLock {
                    $0.selects += 1
                    $0.shapes[sql, default: 0] += 1
                    if sql.range(of: #"FROM ITEMS WHERE ID\s*=\s*\?"#, options: .regularExpression) != nil { $0.points += 1 }
                }
            }
        }
    }

    func finish(on database: DatabaseManager) throws -> MetadataWriteReport {
        try database.writer.writeWithoutTransaction { db in
            db.trace(options: [])
            let rows = try Row.fetchAll(db, sql: "SELECT target, COUNT(*) AS count FROM metadataUpdates GROUP BY target")
            let counts = Dictionary(uniqueKeysWithValues: rows.map { (($0["target"] as String), ($0["count"] as Int)) })
            return state.withLock {
                MetadataWriteReport(updates: counts, selects: $0.selects, pointItemLookups: $0.points, selectShapes: $0.shapes)
            }
        }
    }
}

func incrementalDescriptor(itemID: String = "item", title: String = "Offline example", username: String = "person@example.test",
                           service: String = "example.test", share: String = "share") -> AutoFillDescriptorInput {
    AutoFillDescriptorInput(vaultID: "vault", itemID: itemID, shareID: share, title: title, username: username,
                            serviceIdentifier: service, hasTOTP: false)
}

func incrementalMetadata(title: String = "Offline example", username: String = "person@example.test", url: String? = nil,
                         fields: [FieldKey] = [], modifyTime: Date = Date(timeIntervalSince1970: 2)) -> PassItem {
    PassItem(id: "item", vaultId: "vault", title: title, itemType: .login, subtitle: username, url: url,
             hasTOTP: false, state: "Active", createTime: Date(timeIntervalSince1970: 1), modifyTime: modifyTime,
             useCount: 0, lastUsedAt: nil, fieldKeys: fields)
}
