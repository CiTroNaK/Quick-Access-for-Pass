import Foundation
import GRDB
import Synchronization
import Testing
@testable import Quick_Access_for_Pass

@Suite("Atomic folder catalog synchronization", .timeLimit(.minutes(1)))
struct FolderCatalogSynchronizationTests {
    private let vaults = [PassVault(id: "vault", name: "Vault", shareId: "share")]

    @Test("catalog and original per-item metadata proofs commit together")
    func completeCommit() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("synthetic".utf8))
        let gate = FolderCLIContractFixture.gate()
        let result = try await synchronize(database, gate: gate)
        let proof = try #require(try database.folderCatalogAdmissionProof(vaultID: "vault", gate: gate))
        #expect(result.offlineMetadataProofs.values.first?.folderCatalogProof == proof)
        try await database.reader.read { (db: Database) throws -> Void in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM folders") == 2)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM folderAncestors") == 3)
            #expect(try String.fetchOne(db, sql: "SELECT folderId FROM folderItemMemberships WHERE itemId = 'item'") == "child")
        }
    }

    @Test("failed discovery retains membership and cached access but defers new admission")
    func deferredDiscovery() async throws {
        let fixture = try OfflineSyncPlanningFixture()
        try await fixture.cache()
        let gate = FolderCLIContractFixture.gate()
        _ = try await synchronize(fixture.database, gate: gate)
        _ = try await fixture.database.synchronizeMetadata(
            vaults: vaults, items: [incrementalMetadata(title: "Changed title")], descriptors: [],
            folderCatalogsByVaultID: ["vault": .unavailable], folderFeatureGate: gate,
            operation: fixture.database.beginSyncOperation()
        )
        #expect(try fixture.database.allActiveItems().first?.title == "Changed title")
        #expect(try fixture.database.folderCatalogAdmissionProof(vaultID: "vault", gate: gate) == nil)
        try await fixture.database.reader.read { (db: Database) throws -> Void in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM folders") == 2)
            #expect(try String.fetchOne(db, sql: "SELECT folderId FROM folderItemMemberships") == "child")
            #expect(try String.fetchOne(db, sql: "SELECT reconciliationStatus FROM folderCatalogState") == "deferred")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineSnapshots") == 1)
        }
        let key = OfflineSnapshotKey(vaultId: "vault", itemId: "item", schemaVersion: OfflineSnapshotLimits.schemaVersion)
        #expect(try await fixture.repository.authorizedSnapshot(for: key) != nil)
        try await fixture.repository.removeItem("item")
        #expect(try await fixture.repository.hasPersistedSnapshots() == false)
        // Title changes intentionally dirty payload metadata; deferred discovery itself must not purge it.
        _ = try await synchronize(fixture.database, gate: gate, title: "Changed title")
        #expect(try fixture.database.folderCatalogAdmissionProof(vaultID: "vault", gate: gate) != nil)
    }

    @Test("rename preserves membership generation; parent and membership changes advance it")
    func structuralGenerations() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("synthetic".utf8))
        let gate = FolderCLIContractFixture.gate()
        _ = try await synchronize(database, gate: gate)
        let original = try #require(try database.folderCatalogAdmissionProof(vaultID: "vault", gate: gate))
        _ = try await synchronize(database, gate: gate, childName: "Renamed / child")
        let renamed = try #require(try database.folderCatalogAdmissionProof(vaultID: "vault", gate: gate))
        #expect(renamed.membershipGeneration == original.membershipGeneration)
        // Renames are display-only: an unchanged structure under the same probe keeps its observation.
        #expect(renamed.observationID == original.observationID)
        _ = try await synchronize(database, gate: gate, childParent: nil)
        let moved = try #require(try database.folderCatalogAdmissionProof(vaultID: "vault", gate: gate))
        #expect(moved.membershipGeneration != renamed.membershipGeneration)
        _ = try await synchronize(database, gate: gate, membership: .root)
        let root = try #require(try database.folderCatalogAdmissionProof(vaultID: "vault", gate: gate))
        #expect(root.membershipGeneration != moved.membershipGeneration)
    }

    @Test("a new probe stamp rotates the observation of an unchanged catalog")
    func newStampRotatesObservation() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("synthetic".utf8))
        let gate = FolderCLIContractFixture.gate()
        _ = try await synchronize(database, gate: gate)
        let original = try #require(try database.folderCatalogAdmissionProof(vaultID: "vault", gate: gate))
        _ = try await synchronize(database, gate: gate)
        #expect(try database.folderCatalogAdmissionProof(vaultID: "vault", gate: gate) == original)
        gate.confirm(capabilities: .init(rawVersionString: "2.5.1"), for: gate.beginProbe())
        _ = try await synchronize(database, gate: gate)
        let reprobed = try #require(try database.folderCatalogAdmissionProof(vaultID: "vault", gate: gate))
        #expect(reprobed.observationID != original.observationID)
        #expect(reprobed.membershipGeneration == original.membershipGeneration)
    }

    @Test("descriptor failure rolls back folders, items, and observation proof")
    func rollback() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("synthetic".utf8))
        let gate = FolderCLIContractFixture.gate()
        _ = try await synchronize(database, gate: gate)
        let before = try database.folderCatalogAdmissionProof(vaultID: "vault", gate: gate)
        let catalog = try makeCatalog(gate: gate, childName: "Must roll back")
        await #expect(throws: ForcedFailure.rollback) {
            _ = try await database.synchronizeMetadata(vaults: vaults, items: [incrementalMetadata(title: "Must roll back")],
                descriptors: [], folderCatalogsByVaultID: ["vault": .complete(catalog)], folderFeatureGate: gate,
                operation: database.beginSyncOperation(), beforeDescriptorWrite: { throw ForcedFailure.rollback })
        }
        #expect(try database.folderCatalogAdmissionProof(vaultID: "vault", gate: gate) == before)
        #expect(try database.allActiveItems().first?.title == "Offline example")
        try await database.reader.read { (db: Database) throws -> Void in
            #expect(try String.fetchOne(db, sql: "SELECT name FROM folders WHERE id = 'child'") == "Child")
        }
    }

    @Test("stale gate evidence is deferred while ordinary metadata still commits")
    func staleStamp() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("synthetic".utf8))
        let gate = FolderCLIContractFixture.gate()
        let catalog = try makeCatalog(gate: gate)
        gate.invalidateSelection()
        _ = try await database.synchronizeMetadata(vaults: vaults, items: [incrementalMetadata()], descriptors: [],
            folderCatalogsByVaultID: ["vault": .complete(catalog)], folderFeatureGate: gate, operation: database.beginSyncOperation())
        #expect(try database.allActiveItems().count == 1)
        #expect(try database.folderCatalogAdmissionProof(vaultID: "vault", gate: gate) == nil)
        try await database.reader.read { (db: Database) throws -> Void in #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM folders") == 0) }
    }

    @Test("a superseded queued sync cannot overwrite a newer catalog")
    func queuedOlderCatalog() async throws {
        let pause = OwnershipPause()
        let first = Mutex(true)
        let database = try DatabaseManager(inMemory: true, passphrase: Data("synthetic".utf8),
            offlineMutationTesting: OfflineMutationTesting(afterAdmission: { _ in
                let shouldPause = first.withLock { value in defer { value = false }; return value }
                if shouldPause { await pause.suspend() }
            }))
        let gate = FolderCLIContractFixture.gate()
        let olderOperation = database.beginSyncOperation()
        let olderCatalog = try makeCatalog(gate: gate, childName: "Older")
        let older = Task {
            try await database.synchronizeMetadata(vaults: vaults, items: [incrementalMetadata()], descriptors: [],
                folderCatalogsByVaultID: ["vault": .complete(olderCatalog)], folderFeatureGate: gate, operation: olderOperation)
        }
        await pause.waitUntilEntered()
        gate.invalidateSelection()
        gate.confirm(capabilities: .init(rawVersionString: "2.5.1"), for: gate.beginProbe())
        _ = try await synchronize(database, gate: gate, childName: "Newer")
        await pause.finish()
        await #expect(throws: CancellationError.self) { try await older.value }
        try await database.reader.read { (db: Database) throws -> Void in
            #expect(try String.fetchOne(db, sql: "SELECT name FROM folders WHERE id = 'child'") == "Newer")
        }
    }

    @Test("valid empty discovery deletes confirmed policies, and purge/reset clear new tables")
    func emptyPurgeAndReset() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("synthetic".utf8))
        let gate = FolderCLIContractFixture.gate()
        _ = try await synchronize(database, gate: gate)
        try await selectFixtureFolder(in: database)
        let empty = try CLIFolderCatalogParser.parse(Data("[]".utf8), vault: FolderCLIContractFixture.vault,
                                                     memberships: ["item": .root], stamp: FolderCLIContractFixture.stamp())
        // The fixture stamp above is intentionally from another gate: it must not delete anything.
        _ = try await database.synchronizeMetadata(vaults: vaults, items: [incrementalMetadata()], descriptors: [],
            folderCatalogsByVaultID: ["vault": .complete(empty)], folderFeatureGate: gate)
        try await database.reader.read { (db: Database) throws -> Void in #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineFolders") == 1) }
        let currentEmpty = try CLIFolderCatalogParser.parse(Data("[]".utf8), vault: FolderCLIContractFixture.vault,
            memberships: ["item": .root], stamp: #require(gate.supportedStamp()))
        _ = try await database.synchronizeMetadata(vaults: vaults, items: [incrementalMetadata()], descriptors: [],
            folderCatalogsByVaultID: ["vault": .complete(currentEmpty)], folderFeatureGate: gate)
        try await database.reader.read { (db: Database) throws -> Void in #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineFolders") == 0) }
        _ = try await synchronize(database, gate: gate)
        try await selectFixtureFolder(in: database)
        try await OfflineSnapshotRepository(database: database).purge()
        try await database.reader.read { (db: Database) throws -> Void in #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineFolders") == 0) }
        try await database.clearMetadata()
        try await database.reader.read { (db: Database) throws -> Void in
            for table in ["folders", "folderAncestors", "folderCatalogState", "folderItemMemberships"] {
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") == 0)
            }
        }
    }

    @Test("reopened pools defer retained fresh proof when ordinary sync has no folder evidence")
    func reopenRetainsTracking() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("catalog.sqlite").path
        let passphrase = Data("synthetic-reopen".utf8)
        let original = try DatabaseManager(path: path, passphrase: passphrase)
        let gate = FolderCLIContractFixture.gate()
        _ = try await synchronize(original, gate: gate)
        let reopened = try DatabaseManager(path: path, passphrase: passphrase)
        #expect(try reopened.folderCatalogAdmissionProof(vaultID: "vault", gate: gate) != nil)
        _ = try reopened.syncMetadata(vaults: vaults, items: [incrementalMetadata()], descriptors: [])
        #expect(try reopened.folderCatalogAdmissionProof(vaultID: "vault", gate: gate) == nil)
        try await reopened.reader.read { (db: Database) throws -> Void in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM folders") == 2)
        }
    }

    @Test("vault deletion reports folder-policy deletion for bounded maintenance")
    func vaultDeletionMaintenance() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("synthetic".utf8))
        let gate = FolderCLIContractFixture.gate()
        _ = try await synchronize(database, gate: gate)
        try await selectFixtureFolder(in: database)
        let result = try await database.synchronizeMetadata(vaults: [], items: [], descriptors: [], operation: database.beginSyncOperation())
        #expect(result.didDeleteOfflineData)
        try await database.reader.read { (db: Database) throws -> Void in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineFolders") == 0)
        }
    }

    private func synchronize(_ database: DatabaseManager, gate: FolderFeatureGate, title: String = "Offline example",
                             childName: String = "Child", childParent: String? = "root",
                             membership: CLIFolderMembership = .folder("child")) async throws -> MetadataSynchronizationResult {
        let catalog = try makeCatalog(gate: gate, childName: childName, childParent: childParent, membership: membership)
        return try await database.synchronizeMetadata(vaults: vaults, items: [incrementalMetadata(title: title)], descriptors: [],
            folderCatalogsByVaultID: ["vault": .complete(catalog)], folderFeatureGate: gate, operation: database.beginSyncOperation())
    }

    private func makeCatalog(gate: FolderFeatureGate, childName: String = "Child", childParent: String? = "root",
                             membership: CLIFolderMembership = .folder("child")) throws -> ValidatedFolderCatalog {
        try CLIFolderCatalogParser.parse(FolderCLIContractFixture.folders([("root", nil, "Parent"), ("child", childParent, childName)]),
            vault: FolderCLIContractFixture.vault, memberships: ["item": membership], stamp: #require(gate.supportedStamp()))
    }

    private func selectFixtureFolder(in database: DatabaseManager) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "INSERT INTO offlineFolders VALUES ('vault', 'child', ?, 1)", arguments: [UUID().uuidString])
        }
    }

    private enum ForcedFailure: Error, Equatable { case rollback }
}
