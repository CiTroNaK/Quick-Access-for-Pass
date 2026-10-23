import GRDB

nonisolated extension DatabaseManager {
    static func registerOfflineSnapshotContentMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v16") { db in
            try db.alter(table: "offlineSnapshots") { table in
                table.add(column: "contentRevision", .integer)
                    .notNull()
                    .defaults(to: 0)
                    .check(sql: "contentRevision >= 0")
            }
        }
    }
}
