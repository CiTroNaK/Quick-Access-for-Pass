import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

/// Synthetic CLI bodies remain exclusively in this test runner, never production lifecycle registrations.
@MainActor
struct OfflineFolderSyncFixture {
    let folder: OfflineFolderFixture
    let cli: PassCLIService
    let runner: OfflineFolderSyncRunner
    let codec: IncrementalSyncCodec
    let keys: OfflineFolderSyncKeys
    let identityBarrier: OfflineFolderSyncIdentityBarrier
    let publicationBarrier: OfflineFolderSyncPublicationBarrier
    let service: OfflineModeService
    let coordinator: SyncCoordinator
    let viewModel: QuickAccessViewModel
    let defaults: UserDefaults
    let suiteName: String

    static func make(selectParent: Bool = true, initialized: Bool = true) async throws -> Self {
        let runner = OfflineFolderSyncRunner()
        let cli = PassCLIService(cliPath: "/fake/pass", runner: runner)
        _ = try #require(await cli.prepareFolderSync())
        let publicationBarrier = OfflineFolderSyncPublicationBarrier()
        let folder = try OfflineFolderFixture(gate: cli.folderFeatureGate, beforePublication: { await publicationBarrier.waitIfHeld() })
        try await folder.synchronize()
        if selectParent { _ = try await folder.select("parent") }
        let repository = folder.repository
        let keys = OfflineFolderSyncKeys()
        let codec = IncrementalSyncCodec(base: OfflineSnapshotCodec(keyMaterialProvider: keys, hasPersistedSnapshots: {
            try await repository.hasPersistedSnapshots()
        }))
        let service = OfflineModeService(repository: repository, codec: codec, cliService: cli)
        if initialized { try await initializeOfflineFixtureService(service) }
        let viewModel = QuickAccessViewModel(searchService: SearchService(databaseManager: folder.database), cliService: cli,
            clipboardManager: ClipboardManager(autoClearSeconds: 0), onDismiss: {}, writeStringToPasteboard: { _ in }, openURL: { _ in true })
        let suiteName = "OfflineFolderSync.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let identityBarrier = OfflineFolderSyncIdentityBarrier()
        let coordinator = SyncCoordinator(cliService: cli, databaseManager: folder.database, viewModel: viewModel,
                                          identitySynchronizer: identityBarrier, offlineModeService: service, defaults: defaults)
        return Self(folder: folder, cli: cli, runner: runner, codec: codec, keys: keys, identityBarrier: identityBarrier,
                    publicationBarrier: publicationBarrier, service: service,
                    coordinator: coordinator, viewModel: viewModel, defaults: defaults, suiteName: suiteName)
    }

    func sync(whileListHeld body: (@MainActor () async throws -> Void)? = nil) async throws {
        if let body {
            let barrier = IncrementalSyncGate()
            await runner.holdNextList(barrier)
            try await pausedSync(barrier: barrier, body: body)
        } else {
            coordinator.refreshNow()
            await coordinator.currentSyncCompletion?.value
        }
    }

    func sync(whileMetadataHeld body: @MainActor () async throws -> Void) async throws {
        let barrier = IncrementalSyncGate()
        await identityBarrier.holdNext(barrier)
        try await pausedSync(barrier: barrier, body: body)
    }

    func sync(whilePublicationHeld body: @MainActor () async throws -> Void) async throws {
        let barrier = IncrementalSyncGate()
        await publicationBarrier.holdNext(barrier)
        try await pausedSync(barrier: barrier, body: body)
    }

    func sync(preparing itemIDs: Set<String>, whilePreparationHeld body: @MainActor () async throws -> Void) async throws {
        let barrier = IncrementalSyncGate()
        await codec.setGate(barrier, itemIDs: itemIDs)
        try await pausedSync(barrier: barrier, body: body)
        await codec.setGate(nil)
    }

    private func pausedSync(barrier: IncrementalSyncGate, body: @MainActor () async throws -> Void) async throws {
        coordinator.refreshNow()
        let originalCompletion = coordinator.currentSyncCompletion
        await barrier.waitUntilEntered()
        do { try await body() }
        catch {
            await barrier.open()
            await originalCompletion?.value
            await coordinator.currentSyncCompletion?.value
            throw error
        }
        await barrier.open()
        await originalCompletion?.value
        await coordinator.currentSyncCompletion?.value
    }

    func replaceCatalog(childParent: String? = "parent", otherParent: String? = nil,
                        memberships: [String: CLIFolderMembership] = ["item": .folder("child"), "new": .folder("child")],
                        operation: SyncOperationToken? = nil) async throws {
        let catalog = try CLIFolderCatalogParser.parse(FolderCLIContractFixture.folders([
            ("parent", nil, "Parent"), ("child", childParent, "Child"), ("other", otherParent, "Other"), ("empty", nil, "Empty")
        ]), vault: FolderCLIContractFixture.vault, memberships: memberships, stamp: #require(cli.folderFeatureGate.supportedStamp()))
        _ = try await folder.database.synchronizeMetadata(vaults: folder.database.allVaults(), items: folder.database.allActiveItems(),
            descriptors: folder.database.allAutoFillDescriptors().map(\.sourceInput), folderCatalogsByVaultID: ["vault": .complete(catalog)],
            folderFeatureGate: cli.folderFeatureGate, operation: operation ?? folder.database.beginSyncOperation())
    }

    func commit(_ result: CLISyncFetchResult, operation: SyncOperationToken) async throws -> MetadataSynchronizationResult {
        let items = result.items.map { PassItem(from: $0.item, vaultId: $0.vaultId) }
        let descriptors = zip(result.items, items).flatMap { AutoFillCredentialDescriptor.inputs(from: $0.0.item, metadata: $0.1, shareID: "share") }
        return try await folder.database.synchronizeMetadata(vaults: [PassVault(id: "vault", name: "Vault", shareId: "share")], items: items,
            descriptors: descriptors, presenceUncertainties: result.presenceUncertainties, folderCatalogsByVaultID: result.folderCatalogsByVaultID,
            folderFeatureGate: cli.folderFeatureGate, operation: operation)
    }

    func snapshot(_ itemID: String = "new") async throws -> EncryptedOfflineSnapshot? { try await folder.snapshot(itemID: itemID) }
    func scalar(_ sql: String) async throws -> Int {
        // Fixed test-authored metadata queries only.
        try await folder.database.reader.read { try Int.fetchOne($0, sql: sql) ?? 0 }
    }
    func finish() async {
        await service.stop()
        defaults.removePersistentDomain(forName: suiteName)
    }
}

/// Does not contact or mutate the real system identity store.
actor OfflineFolderSyncIdentityBarrier: AutoFillIdentitySynchronizing {
    private var nextGate: IncrementalSyncGate?
    func holdNext(_ gate: IncrementalSyncGate) { nextGate = gate }
    func reconcile(descriptors: [AutoFillCredentialDescriptor], isCurrent: @escaping @Sendable () -> Bool) async throws {
        if let gate = nextGate { nextGate = nil; await gate.wait() }
        guard isCurrent() else { throw CancellationError() }
    }
}

actor OfflineFolderSyncPublicationBarrier {
    private var nextGate: IncrementalSyncGate?
    func holdNext(_ gate: IncrementalSyncGate) { nextGate = gate }
    func waitIfHeld() async { if let gate = nextGate { nextGate = nil; await gate.wait() } }
}

actor OfflineFolderSyncKeys: OfflineSnapshotKeyProviding {
    private var calls = 0
    func existingSnapshotKey() -> Data? { calls += 1; return Data(repeating: 7, count: 32) }
    func createSnapshotKey() -> Data { calls += 1; return Data(repeating: 7, count: 32) }
    func callCount() -> Int { calls }
}

actor OfflineFolderSyncRunner: CLIRunning {
    private var version = "2.5.1"
    private var memberships: [String: CLIFolderMembership] = ["item": .folder("child"), "new": .folder("child")]
    private var parentName = "Parent"
    private var modifyTime = "1970-01-01T00:00:02Z"
    private var password = "synthetic"
    private var childParent: String? = "parent"
    private var folderFailure = false
    private var malformedIDs: Set<String> = []
    private var nextListGate: IncrementalSyncGate?
    private var history: [[String]] = []

    func setVersion(_ version: String) { self.version = version }
    func setMemberships(_ memberships: [String: CLIFolderMembership]) { self.memberships = memberships }
    func setParentName(_ name: String) { parentName = name }
    func setSourceTime(_ time: String) { modifyTime = time }
    func setPassword(_ value: String) { password = value }
    func setChildParent(_ id: String?) { childParent = id }
    func failFolderDiscovery(_ value: Bool) { folderFailure = value }
    func setMalformedIDs(_ ids: Set<String>) { malformedIDs = ids }
    func holdNextList(_ gate: IncrementalSyncGate) { nextListGate = gate }
    func arguments() -> [[String]] { history }
    func views() -> [[String]] { history.filter { $0.starts(with: ["item", "view"]) } }

    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        history.append(arguments)
        if arguments == ["--version"] { return Data("pass-cli \(version)".utf8) }
        if arguments.starts(with: ["vault", "list"]) {
            return Data("{\"vaults\":[{\"vault_id\":\"vault\",\"share_id\":\"share\",\"name\":\"Vault\"}]}".utf8)
        }
        if arguments.starts(with: ["item", "list"]) {
            let rows = try memberships.keys.sorted().map { try itemObject($0, malformed: malformedIDs.contains($0)) }
            let data = try JSONSerialization.data(withJSONObject: ["items": rows])
            if let gate = nextListGate { nextListGate = nil; await gate.wait() }
            return data
        }
        if arguments.starts(with: ["folder", "list"]) {
            if folderFailure { throw CLIError.commandFailed("synthetic catalog unavailable") }
            return try FolderCLIContractFixture.folders([
                ("parent", nil, parentName), ("child", childParent, "Child"), ("other", nil, "Other"), ("empty", nil, "Empty")
            ])
        }
        if arguments.starts(with: ["item", "view"]), let uri = arguments.last, let id = uri.split(separator: "/").last {
            return try JSONSerialization.data(withJSONObject: ["item": itemObject(String(id), malformed: false)])
        }
        throw CLIError.commandFailed("synthetic unexpected command")
    }

    private func itemObject(_ id: String, malformed: Bool) throws -> [String: Any] {
        if malformed { return ["id": id, "state": "Active", "content": false, "folder_id": "child"] }
        let item = try incrementalSyncCLIItem(id: id, password: password, modifyTime: modifyTime, title: id)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        object["share_id"] = "share"
        switch memberships[id] ?? .root {
        case .folder(let id): object["folder_id"] = id
        case .root: object["folder_id"] = NSNull()
        case .unknown: object["folder_id"] = false
        }
        return object
    }
}
