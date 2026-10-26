import GRDB

nonisolated extension DatabaseManager {
    static func registerFolderMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v17") { db in
            // Additive metadata only: no payload/key reads, conversion, or ordinary-data wipe.
            try db.execute(sql: """
                CREATE TABLE folders (
                    vaultId TEXT NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
                    id TEXT NOT NULL, name TEXT NOT NULL, parentId TEXT,
                    PRIMARY KEY (vaultId, id)
                );
                CREATE TABLE folderAncestors (
                    vaultId TEXT NOT NULL, folderId TEXT NOT NULL, ancestorId TEXT NOT NULL,
                    depth INTEGER NOT NULL CHECK (depth >= 0 AND depth < 64),
                    PRIMARY KEY (vaultId, folderId, ancestorId),
                    FOREIGN KEY (vaultId, folderId) REFERENCES folders(vaultId, id) ON DELETE CASCADE,
                    FOREIGN KEY (vaultId, ancestorId) REFERENCES folders(vaultId, id) ON DELETE CASCADE
                );
                CREATE INDEX folderAncestors_byAncestor ON folderAncestors(vaultId, ancestorId, folderId);
                CREATE TABLE folderCatalogState (
                    vaultId TEXT NOT NULL PRIMARY KEY REFERENCES vaults(id) ON DELETE CASCADE,
                    membershipGeneration TEXT NOT NULL, observationId TEXT NOT NULL,
                    selectionGeneration TEXT, probeRevision TEXT,
                    reconciliationStatus TEXT NOT NULL CHECK (reconciliationStatus IN ('fresh', 'deferred')),
                    CHECK (reconciliationStatus != 'fresh' OR (selectionGeneration IS NOT NULL AND probeRevision IS NOT NULL))
                );
                CREATE TABLE folderItemMemberships (
                    vaultId TEXT NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
                    itemId TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                    folderId TEXT,
                    PRIMARY KEY (vaultId, itemId),
                    FOREIGN KEY (vaultId, folderId) REFERENCES folders(vaultId, id) ON DELETE CASCADE
                );
                CREATE INDEX folderItemMemberships_byFolder ON folderItemMemberships(vaultId, folderId, itemId);
                CREATE TABLE offlineFolders (
                    vaultId TEXT NOT NULL, folderId TEXT NOT NULL,
                    policyGeneration TEXT NOT NULL, selectedAt DATETIME NOT NULL,
                    PRIMARY KEY (vaultId, folderId),
                    FOREIGN KEY (vaultId, folderId) REFERENCES folders(vaultId, id) ON DELETE CASCADE
                );
                CREATE TABLE offlineSyncCaptureFolders (
                    captureId TEXT NOT NULL REFERENCES offlineSyncCaptures(id) ON DELETE CASCADE,
                    vaultId TEXT NOT NULL, folderId TEXT NOT NULL, policyGeneration TEXT NOT NULL,
                    PRIMARY KEY (captureId, vaultId, folderId)
                );
                """)
        }
    }
}
