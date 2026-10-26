import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

nonisolated struct OfflineFolderFixture: Sendable {
    let database: DatabaseManager
    let gate: FolderFeatureGate
    let repository: OfflineSnapshotRepository

    static let initialMemberships: [String: CLIFolderMembership] = [
        "item": .folder("child"), "other-item": .folder("other"), "root-item": .root
    ]

    init(database: DatabaseManager? = nil, testing: OfflineMutationTesting? = nil, gate: FolderFeatureGate? = nil,
         beforePublication: @escaping @Sendable () async -> Void = {}) throws {
        self.database = try database ?? DatabaseManager(inMemory: true, passphrase: Data("synthetic-folder-policy".utf8), offlineMutationTesting: testing)
        self.gate = gate ?? FolderCLIContractFixture.gate()
        repository = OfflineSnapshotRepository(database: self.database, beforePublication: beforePublication, folderFeatureGate: self.gate)
    }

    static func make(database: DatabaseManager? = nil) async throws -> Self {
        let value = try Self(database: database)
        try await value.synchronize()
        return value
    }

    func synchronize(memberships: [String: CLIFolderMembership] = initialMemberships,
                     childParent: String? = "parent", parentName: String = "Parent",
                     failure: Bool = false, deletingFolders: Set<String> = [],
                     beforeDescriptorWrite: @escaping @Sendable () throws -> Void = {}) async throws {
        let outcome: FolderCatalogFetchOutcome
        if failure { outcome = .unavailable }
        else {
            let rows: [(String, String?, String)] = [
                ("parent", nil, parentName), ("child", childParent, "Child"), ("other", nil, "Other"), ("empty", nil, "Empty")
            ]
            let catalog = try CLIFolderCatalogParser.parse(FolderCLIContractFixture.folders(rows.filter { !deletingFolders.contains($0.0) }),
                vault: FolderCLIContractFixture.vault, memberships: memberships, stamp: #require(gate.supportedStamp()))
            outcome = .complete(catalog)
        }
        _ = try await database.synchronizeMetadata(
            vaults: [PassVault(id: "vault", name: "Vault", shareId: "share")],
            items: memberships.keys.sorted().map { offlineTestMetadata(id: $0, vaultID: "vault") }, descriptors: [],
            folderCatalogsByVaultID: ["vault": outcome], folderFeatureGate: gate,
            operation: database.beginSyncOperation(), beforeDescriptorWrite: beforeDescriptorWrite
        )
    }

    @discardableResult
    func select(_ folderID: String, selected: Bool = true) async throws -> OfflineFolderSelection? {
        try await repository.setFolderSelected(selected, folderID: folderID, vaultID: "vault", featureStamp: gate.supportedStamp())
    }

    func cache(_ selection: OfflineFolderSelection, itemID: String = "item", totp: String = "") async throws {
        let request = try #require(try await repository.beginRequest(itemID: itemID, vaultID: "vault", shareID: "share",
            kind: .folderSelection(folderID: selection.folderID, policyGeneration: selection.generation)))
        try await publish(request, totp: totp)
    }

    func cacheManually(itemID: String = "item") async throws {
        let request = try #require(try await repository.beginRequest(itemID: itemID, vaultID: "vault", shareID: "share", kind: .selection))
        try await publish(request)
    }

    func codec() -> OfflineSnapshotCodec {
        let repository = repository
        return OfflineSnapshotCodec(keyMaterialProvider: OfflineFixtureKeys(), hasPersistedSnapshots: {
            try await repository.hasPersistedSnapshots()
        })
    }

    private func publish(_ request: OfflineRequestToken, totp: String = "") async throws {
        let item = try offlineTestCLIItem(id: request.key.itemId, vaultID: "vault", shareID: "share",
                                         password: "synthetic", totp: totp, modifyTime: "1970-01-01T00:00:02Z")
        let prepared = try await codec().prepareSnapshot(from: item, for: request)
        #expect(try await repository.publish(prepared, for: request, refreshedAt: Date(timeIntervalSince1970: 3)))
    }

    func service(viewer: OfflineFixtureViewer) async throws -> OfflineModeService {
        let service = OfflineModeService(repository: repository, codec: codec(), cliService: viewer)
        try await service.initialize()
        let generation = UUID()
        await service.updateSelectionObservation(generation: generation, status: .starting)
        await service.updateSelectionObservation(generation: generation, status: .fresh)
        return service
    }

    func snapshot(itemID: String = "item") async throws -> EncryptedOfflineSnapshot? {
        try await repository.authorizedSnapshot(for: key(itemID))
    }

    func key(_ itemID: String = "item") -> OfflineSnapshotKey {
        OfflineSnapshotKey(vaultId: "vault", itemId: itemID, schemaVersion: OfflineSnapshotLimits.schemaVersion)
    }
}
