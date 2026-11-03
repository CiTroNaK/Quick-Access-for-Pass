import Foundation
import GRDB

nonisolated struct FolderCatalogStoredMetadata: Sendable {
    var parentsByID: [String: String?] = [:]
    var memberships: [String: CLIFolderMembership] = [:]
    var generation: UUID?
    var status: String?
    var observationID: UUID?
    var stamp: FolderFeatureStamp?
}

nonisolated struct FolderCatalogWriteResult: Sendable {
    var proofsByVaultID: [String: FolderCatalogAdmissionProof] = [:]
    var didDeleteOfflineData = false
}

nonisolated extension DatabaseManager {
    /// Presentation callers cannot manufacture admission from an old catalog or UI rows.
    func folderCatalogAdmissionProof(vaultID: String, gate: FolderFeatureGate) throws -> FolderCatalogAdmissionProof? {
        try reader.read { db in try Self.folderCatalogAdmissionProof(vaultID: vaultID, gate: gate, in: db) }
    }

    static func folderCatalogAdmissionProof(
        vaultID: String, gate: FolderFeatureGate, in db: Database
    ) throws -> FolderCatalogAdmissionProof? {
        guard let stamp = gate.supportedStamp(),
              let row = try Row.fetchOne(db, sql: """
                SELECT observationId, membershipGeneration FROM folderCatalogState
                WHERE vaultId = ? AND reconciliationStatus = 'fresh' AND selectionGeneration = ? AND probeRevision = ?
                """, arguments: [vaultID, stamp.selectionGeneration.uuidString, stamp.probeRevision.uuidString]),
              let observation = UUID(uuidString: row["observationId"]),
              let generation = UUID(uuidString: row["membershipGeneration"]), gate.isCurrent(stamp) else { return nil }
        return FolderCatalogAdmissionProof(vaultID: vaultID, observationID: observation,
            membershipGeneration: generation, stamp: stamp)
    }

    /// Captured before ordinary metadata writes so FK-driven membership removal is a structural change too.
    static func storedFolderMetadata(in db: Database) throws -> [String: FolderCatalogStoredMetadata] {
        var result: [String: FolderCatalogStoredMetadata] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT vaultId, id, parentId FROM folders") {
            let vaultID: String = row["vaultId"]
            let id: String = row["id"]
            let parent: String? = row["parentId"]
            result[vaultID, default: FolderCatalogStoredMetadata()].parentsByID.updateValue(parent, forKey: id)
        }
        for row in try Row.fetchAll(db, sql: "SELECT vaultId, itemId, folderId FROM folderItemMemberships") {
            let vaultID: String = row["vaultId"]
            let itemID: String = row["itemId"]
            let folderID: String? = row["folderId"]
            result[vaultID, default: FolderCatalogStoredMetadata()].memberships[itemID] = folderID.map(CLIFolderMembership.folder) ?? .root
        }
        for row in try Row.fetchAll(db, sql: """
            SELECT vaultId, membershipGeneration, observationId, selectionGeneration, probeRevision, reconciliationStatus
            FROM folderCatalogState
            """) {
            let vaultID: String = row["vaultId"]
            var stored = result[vaultID, default: FolderCatalogStoredMetadata()]
            stored.generation = UUID(uuidString: row["membershipGeneration"])
            stored.status = row["reconciliationStatus"]
            stored.observationID = UUID(uuidString: row["observationId"])
            if let selection = (row["selectionGeneration"] as String?).flatMap(UUID.init(uuidString:)),
               let probe = (row["probeRevision"] as String?).flatMap(UUID.init(uuidString:)) {
                stored.stamp = FolderFeatureStamp(selectionGeneration: selection, probeRevision: probe)
            }
            result[vaultID] = stored
        }
        return result
    }
}
