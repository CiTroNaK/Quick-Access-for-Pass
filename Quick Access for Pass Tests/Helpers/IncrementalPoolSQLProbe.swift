import Foundation
import GRDB
import Synchronization
@testable import Quick_Access_for_Pass

nonisolated struct IncrementalPoolSQLReport: Sendable {
    let statements: [String: Int]
    let rows: [String: Int]
    let writerCatalogProjections: Int
    let pointItemLookups: Int
    func rowCount(_ table: String, _ operation: String) -> Int { rows[table + "." + operation, default: 0] }
    func emitCounts(phase: String) throws {
        let object: [String: Any] = ["phase": phase, "writerStatementsByReferencedTable": statements,
                                     "committedRowEvents": rows, "writerCatalogProjections": writerCatalogProjections,
                                     "pointItemLookups": pointItemLookups]
        let encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        print("Encrypted-pool counters: " + String(decoding: encoded, as: UTF8.self))
    }
}

/// Writer completed-statement counts and committed row effects. Never reads expanded SQL,
/// bound arguments, ciphertext or fetched values. Reader catalog counting is explicitly scoped.
nonisolated final class IncrementalPoolSQLProbe: Sendable {
    private struct State {
        var statements: [String: Int] = [:]
        var writerCatalogProjections = 0
        var pointItemLookups = 0
    }
    private let state = Mutex(State())
    private static let tables = ["items", "vaults", "autoFillDescriptors", "offlineItems", "offlineSnapshots",
                                 "offlineSyncCaptures", "offlineSyncCaptureItems", "offlineSyncCaptureVaults"]

    func install(on database: DatabaseManager) throws {
        try database.writer.writeWithoutTransaction { db in
            try db.execute(sql: "CREATE TEMP TABLE qaScaleRows (target TEXT NOT NULL, operation TEXT NOT NULL)")
            for table in Self.tables {
                for operation in ["INSERT", "UPDATE", "DELETE"] {
                    // All interpolated identifiers/labels are fixed test-authored constants.
                    try db.execute(sql: """
                        CREATE TEMP TRIGGER qaScale_\(table)_\(operation) AFTER \(operation) ON main.\(table)
                        BEGIN INSERT INTO qaScaleRows VALUES ('\(table)', '\(operation.lowercased())'); END
                        """)
                }
            }
            trace(db)
        }
    }
    func reset(on database: DatabaseManager) throws {
        try database.writer.writeWithoutTransaction { db in
            db.trace(options: [])
            try db.execute(sql: "DELETE FROM qaScaleRows")
            state.withLock { $0 = State() }
            trace(db)
        }
    }
    func report(on database: DatabaseManager) throws -> IncrementalPoolSQLReport {
        try database.writer.writeWithoutTransaction { db in
            db.trace(options: [])
            defer { trace(db) }
            let entries = try Row.fetchAll(db, sql: "SELECT target, operation, COUNT(*) AS count FROM qaScaleRows GROUP BY target, operation")
            let rows = Dictionary(uniqueKeysWithValues: entries.map {
                (($0["target"] as String) + "." + ($0["operation"] as String), $0["count"] as Int)
            })
            return state.withLock {
                IncrementalPoolSQLReport(statements: $0.statements, rows: rows,
                                         writerCatalogProjections: $0.writerCatalogProjections, pointItemLookups: $0.pointItemLookups)
            }
        }
    }
    func uninstall(from database: DatabaseManager) {
        database.writer.writeWithoutTransaction { $0.trace(options: []) }
    }
    private func trace(_ db: Database) {
        db.trace(options: .profile) { event in
            guard case .profile(let statement, _) = event else { return }
            let sql = statement.sql.replacingOccurrences(of: "\"", with: "").uppercased()
            let operation = sql.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            guard ["SELECT", "INSERT", "UPDATE", "DELETE"].contains(operation) else { return }
            let tokens = Set(sql.split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init))
            self.state.withLock { state in
                for table in Self.tables where tokens.contains(table.uppercased()) {
                    state.statements[table + "." + operation.lowercased(), default: 0] += 1
                }
                if operation == "SELECT", sql.contains("AS HASUSABLESNAPSHOT") { state.writerCatalogProjections += 1 }
                if sql.range(of: #"FROM ITEMS WHERE ID\s*=\s*\?"#, options: .regularExpression) != nil { state.pointItemLookups += 1 }
            }
        }
    }

    /// Counts the actual three SELECTs on the exact pool reader performing this catalog projection.
    /// This is not global tracing of every pooled reader/observation emission.
    static func catalog(in database: DatabaseManager) async throws -> (snapshot: OfflinePresentationSnapshot, selects: Int) {
        let selects = Mutex(0)
        let snapshot = try await database.reader.read { db in
            db.trace(options: .profile) { event in
                if case .profile(let statement, _) = event, statement.sql.uppercased().hasPrefix("SELECT ") {
                    selects.withLock { $0 += 1 }
                }
            }
            defer { db.trace(options: []) }
            return try OfflineCatalogObservation.presentation(in: db)
        }
        return (snapshot, selects.withLock { $0 })
    }
}
