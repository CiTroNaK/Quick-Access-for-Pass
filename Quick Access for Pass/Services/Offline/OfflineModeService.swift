import Foundation

/// UI-facing availability derived only from non-secret offline catalog metadata.
nonisolated enum OfflineItemAvailability: Sendable, Equatable {
    case notCached
    case available(lastRefreshedAt: Date?)
    case stale(lastRefreshedAt: Date?)
    case unavailable
}

/// Live complete-item reader used before an offline snapshot is written.
nonisolated protocol OfflineItemViewing: Sendable {
    func viewItem(itemId: String, shareId: String) async throws -> CLIItem
}

/// Readiness boundary used by offline fallback consumers.
nonisolated protocol OfflineInitializationProviding: Sendable {
    func isReady() async -> Bool
}

extension PassCLIService: OfflineItemViewing {}

/// Coordinates repository reservations with operation-scoped snapshot crypto.
actor OfflineModeService: OfflineModeServicing {
    enum Error: Swift.Error, Equatable, Sendable {
        case notInitialized
        case requestSuperseded
        case persistenceFailed
        case selectionSuspended
        case snapshotUnavailable
    }

    let repository: any OfflineSnapshotPersisting
    let codec: any OfflineSnapshotCoding
    let cliService: any OfflineItemViewing
    /// Shared metadata-only checkpoint lifecycle owner; it has no codec/key dependency.
    private let maintenance: OfflineStorageMaintenance?
    /// Test-only marker for proving a caller joins an already-owned recovery task.
    private let initializationJoinMarker: @Sendable () -> Void
    var ready = false
    var observationGeneration: UUID?
    var observationIsFresh = false
    var workGeneration = UUID()
    var lifecycleGeneration = UUID()
    var resetSuspended = false
    var stopped = false
    var scheduler: OfflineSnapshotWorkScheduler?
    var permits: [UUID: OwnedPermit] = [:]
    var permitDrainWaiters: [CheckedContinuation<Void, Never>] = []
    var revocations: [UUID: WorkScope] = [:]
    var reservations: [OfflineSnapshotKey: OwnedReservation] = [:]
    var submittedKeys: Set<OfflineSnapshotKey> = []
    private var initializationFailed = false
    var initializationAttemptID: UUID?
    var initializationTask: Task<Void, Swift.Error>?

    init(
        repository: any OfflineSnapshotPersisting,
        codec: any OfflineSnapshotCoding,
        cliService: any OfflineItemViewing,
        maintenance: OfflineStorageMaintenance? = nil,
        initializationJoinMarker: @escaping @Sendable () -> Void = {}
    ) {
        self.repository = repository
        self.codec = codec
        self.cliService = cliService
        self.maintenance = maintenance
        self.initializationJoinMarker = initializationJoinMarker
    }

    /// Coalesces recovery. A failed attempt keeps only a non-secret retry state;
    /// callers may explicitly retry without racing the prior recovery task.
    func initialize() async throws {
        guard !stopped else { throw Error.selectionSuspended }
        if ready { return }
        if let initializationTask, let attemptID = initializationAttemptID {
            initializationJoinMarker()
            try await initializationTask.value
            finalizeSuccessfulInitialization(attemptID: attemptID)
            return
        }

        let attemptID = UUID()
        let repository = repository
        let maintenance = maintenance
        let task = Task<Void, Swift.Error> {
            try await repository.recoverAbandonedRequests()
            // Recovery has committed before remnant maintenance is requested.
            await maintenance?.checkpointAtStartup()
        }
        initializationAttemptID = attemptID
        initializationTask = task
        do {
            try await task.value
            finalizeSuccessfulInitialization(attemptID: attemptID)
        } catch {
            guard initializationAttemptID == attemptID else { throw error }
            initializationFailed = true
            initializationTask = nil
            throw error
        }
    }

    private func finalizeSuccessfulInitialization(attemptID: UUID) {
        guard initializationAttemptID == attemptID, !stopped else { return }
        ready = true
        initializationFailed = false
        initializationTask = nil
    }

    func isReady() -> Bool { ready }

    /// Safe non-secret state used to offer an explicit Settings retry.
    func requiresInitializationRetry() -> Bool { initializationFailed }

    /// Returns non-secret catalog state for Settings presentation.
    func offlineVaultIds() async throws -> Set<String> {
        try await repository.offlineVaultIds()
    }

    /// Returns non-secret selected-item metadata for Settings presentation.
    func offlineItemSelections() async throws -> [OfflineItemSelection] {
        try await repository.offlineItemSelections()
    }

    func availability(for item: PassItem) async throws -> OfflineItemAvailability {
        guard let selection = try await repository.offlineItemSelection(itemId: item.id), selection.vaultId == item.vaultId else {
            return .notCached
        }
        return switch selection.cacheStatus {
        case .notCached: .notCached
        case .cached: .available(lastRefreshedAt: selection.lastRefreshedAt)
        case .failed: .stale(lastRefreshedAt: selection.lastRefreshedAt)
        case .unavailable: .unavailable
        }
    }

    /// Legacy sync entry point submits metadata only; the shared scheduler owns preparation.
    func refreshSelectedSnapshots(vaults: [PassVault], items: [PassItem]) async {
        await metadataDidSynchronize(allowMembershipExpansion: false, eligibleItemIDs: Set(items.map(\.id)))
    }

    /// Fetches and encrypts outside the repository transaction so decoded values never span publication.
    private func preparedSnapshot(for request: OfflineRequestToken) async throws -> EncryptedOfflineSnapshot {
        let item = try await cliService.viewItem(itemId: request.key.itemId, shareId: request.shareID)
        try Task.checkCancellation()
        return try await codec.prepareSnapshot(from: item, for: request)
    }

    func prepareAndPublish(request: OfflineRequestToken, lifecycle: UUID) async throws {
        do {
            let snapshot = try await preparedSnapshot(for: request)
            try Task.checkCancellation()
            guard lifecycleGeneration == lifecycle, !stopped, !resetSuspended else { throw Error.requestSuperseded }
            guard try await repository.publish(snapshot, for: request, refreshedAt: Date()) else {
                throw Error.requestSuperseded
            }
        } catch {
            let failed = !(error is CancellationError)
            await finish(request, failed: failed)
            if error is CancellationError { throw CancellationError() }
            if let error = error as? Error { throw error }
            throw Error.snapshotUnavailable
        }
    }

    /// Completion must release only this request even after caller cancellation.
    func finish(_ request: OfflineRequestToken, failed: Bool) async {
        let repository = repository
        let completion = Task.detached {
            try? await repository.finishRequest(request, failed: failed)
        }
        _ = await completion.value
    }

    func requireReady() throws {
        guard ready else { throw Error.notInitialized }
    }
}
