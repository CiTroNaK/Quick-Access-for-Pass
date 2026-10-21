import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

func incrementalSyncCLIItem(id: String = "item", password: String = "synthetic", note: String = "",
                            modifyTime: String = "1970-01-01T00:00:02Z", title: String = "Offline example", url: String? = nil) throws -> CLIItem {
    let base = try offlineTestCLIItem(id: id, vaultID: "vault", shareID: "share", password: password, note: note, modifyTime: modifyTime)
    var raw = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
    raw["create_time"] = "1970-01-01T00:00:01Z"
    var content = try #require(raw["content"] as? [String: Any])
    content["title"] = title
    if let url {
        var payload = try #require(content["content"] as? [String: Any])
        var login = try #require(payload["Login"] as? [String: Any])
        login["urls"] = [url]
        payload["Login"] = login
        content["content"] = payload
    }
    raw["content"] = content
    return try JSONDecoder().decode(CLIItem.self, from: JSONSerialization.data(withJSONObject: raw))
}

/// Explicit non-cancellable native-work stand-in. Only metadata continuations are retained.
actor IncrementalSyncGate {
    private var entered = false
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entries: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        let current = entries
        entries.removeAll()
        current.forEach { $0.resume() }
        if !opened { await withCheckedContinuation { waiters.append($0) } }
    }
    func waitUntilEntered() async { if !entered { await withCheckedContinuation { entries.append($0) } } }
    func open() {
        opened = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}

/// Test-only complete responses; production must never retain decoded items in its operation registry.
actor IncrementalSyncViewer {
    private var items: [String: CLIItem] = [:]
    private var requests: [String] = []
    private var gate: IncrementalSyncGate?
    func setItems(_ items: [CLIItem]) { self.items = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) }) }
    func setGate(_ gate: IncrementalSyncGate?) { self.gate = gate }
    func viewItem(itemId: String, shareId: String) async throws -> CLIItem {
        requests.append(itemId)
        await gate?.wait()
        guard let item = items[itemId] else { throw CLIError.commandFailed("synthetic unavailable") }
        return item
    }
    func calls() -> [String] { requests }
    func resetCalls() { requests.removeAll() }
}
extension IncrementalSyncViewer: OfflineItemViewing {}

actor IncrementalSyncCodec {
    let base: OfflineSnapshotCodec
    private var gate: IncrementalSyncGate?
    private var gateIDs: Set<String> = []
    private var failureIDs: Set<String> = []
    private var missingMarkerIDs: Set<String> = []
    private var active = 0
    private var peak = 0
    private var prepared = 0
    init(base: OfflineSnapshotCodec) { self.base = base }
    func setGate(_ gate: IncrementalSyncGate?, itemIDs: Set<String> = []) { self.gate = gate; gateIDs = itemIDs }
    func setFailures(_ ids: Set<String>) { failureIDs = ids }
    func setMissingMarkers(_ ids: Set<String>) { missingMarkerIDs = ids }
    func prepareSnapshot(from item: CLIItem, for identity: OfflineSnapshotPreparationIdentity) async throws -> PreparedOfflineSnapshot {
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        if gateIDs.isEmpty || gateIDs.contains(item.id) { await gate?.wait() }
        if failureIDs.contains(item.id) { throw OfflineSnapshotCodec.Error.corruptSnapshot }
        let result = try await base.prepareSnapshot(from: item, for: identity)
        prepared += 1
        if missingMarkerIDs.contains(item.id) { return PreparedOfflineSnapshot(snapshot: result.snapshot, sourceModifyTime: nil) }
        return result
    }
    func decodeSnapshot(_ snapshot: EncryptedOfflineSnapshot) async throws -> CLIItem { try await base.decodeSnapshot(snapshot) }
    func counts() -> (prepared: Int, peak: Int) { (prepared, peak) }
}
extension IncrementalSyncCodec: OfflineSnapshotCoding {}

nonisolated struct IncrementalOfflineSyncFixture: Sendable {
    let database: DatabaseManager
    let repository: OfflineSnapshotRepository
    let persisting: any OfflineSnapshotPersisting
    let codec: IncrementalSyncCodec
    let viewer: IncrementalSyncViewer
    let service: OfflineModeService
    let itemIDs: [String]

    init(itemIDs: [String] = ["item"], database: DatabaseManager? = nil, persisting: (any OfflineSnapshotPersisting)? = nil,
         seedMetadata: Bool = true, stopAdmissionMarker: @escaping @Sendable () -> Void = {},
         keyMaterialProvider: any OfflineSnapshotKeyProviding = OfflineFixtureKeys()) throws {
        let database = try database ?? DatabaseManager(inMemory: true, passphrase: Data("synthetic-incremental-sync".utf8))
        self.database = database
        self.itemIDs = itemIDs
        repository = OfflineSnapshotRepository(database: database)
        let storage = persisting ?? repository
        self.persisting = storage
        let base = OfflineSnapshotCodec(keyMaterialProvider: keyMaterialProvider, hasPersistedSnapshots: { try await storage.hasPersistedSnapshots() })
        codec = IncrementalSyncCodec(base: base)
        viewer = IncrementalSyncViewer()
        service = OfflineModeService(repository: storage, codec: codec, cliService: viewer, stopAdmissionMarker: stopAdmissionMarker)
        if seedMetadata {
            try database.upsertVaults([PassVault(id: "vault", name: "Vault", shareId: "share")])
            try database.upsertItems(itemIDs.map { offlineTestMetadata(id: $0, vaultID: "vault") })
        }
    }

    func initialize() async throws { try await initializeOfflineFixtureService(service) }
    func select(_ ids: [String]? = nil) async throws {
        for id in ids ?? itemIDs { _ = try await repository.selectItemManually(itemID: id, vaultID: "vault", shareID: "share") }
    }
    func result(_ items: [CLIItem], provenance: CLISnapshotContentProvenance = .completeJSONV1,
                uncertainties: [SyncItemPresenceUncertainty] = []) throws -> CLISyncFetchResult {
        let vault = try JSONDecoder().decode(CLIVault.self, from: Data("{\"vault_id\":\"vault\",\"share_id\":\"share\",\"name\":\"Vault\"}".utf8))
        return CLISyncFetchResult(vaults: [vault], items: items.map { ($0, "vault") }, skippedItems: [],
                                 presenceUncertainties: uncertainties, contentProvenanceByVaultID: ["vault": provenance])
    }
    func commit(_ result: CLISyncFetchResult, operation: SyncOperationToken) async throws -> MetadataSynchronizationResult {
        let items = result.items.map { PassItem(from: $0.item, vaultId: $0.vaultId) }
        let inputs = zip(result.items, items).flatMap { AutoFillCredentialDescriptor.inputs(from: $0.0.item, metadata: $0.1, shareID: "share") }
        return try await database.synchronizeMetadata(vaults: [PassVault(id: "vault", name: "Vault", shareId: "share")],
                                                       items: items, descriptors: inputs, presenceUncertainties: result.presenceUncertainties,
                                                       operation: operation)
    }
    @discardableResult
    func sync(_ items: [CLIItem], provenance: CLISnapshotContentProvenance = .completeJSONV1) async throws -> MetadataSynchronizationResult {
        let operation = database.beginSyncOperation()
        let capture = await service.captureForSync(operation: operation)
        do {
            let result = try result(items, provenance: provenance)
            let metadata = try await commit(result, operation: operation)
            if let capture {
                try await service.consumeSyncResult(result, capture: capture, metadataProofs: metadata.offlineMetadataProofs,
                                                    allowMembershipExpansion: true)
                await service.finishSyncCapture(capture)
            }
            return metadata
        } catch {
            if let capture { await service.finishSyncCapture(capture) }
            throw error
        }
    }
    func snapshot(_ id: String = "item") async throws -> EncryptedOfflineSnapshot? {
        try await repository.authorizedSnapshot(for: OfflineSnapshotKey(vaultId: "vault", itemId: id, schemaVersion: 1))
    }
    func baseline(_ id: String = "item") async throws -> Date? {
        try await database.reader.read { try Date.fetchOne($0, sql: "SELECT sourceModifyTime FROM offlineSnapshots WHERE itemId = ?", arguments: [id]) }
    }
}
