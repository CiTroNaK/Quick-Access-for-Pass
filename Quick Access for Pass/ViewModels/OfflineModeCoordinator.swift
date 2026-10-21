import Foundation
import Observation

/// Non-secret catalog metadata needed to present an offline vault.
nonisolated struct OfflineVaultSettingsRow: Sendable, Equatable, Identifiable {
    let id: String
    let vaultName: String
    let isSelected: Bool
    let selectedCount: Int
    let usableCount: Int
    let lastRefreshedAt: Date?
}

/// Non-secret catalog metadata needed to present an offline item.
nonisolated struct OfflineItemSettingsRow: Sendable, Equatable, Identifiable {
    let itemId: String
    let vaultId: String
    let title: String
    let itemType: ItemType
    let status: OfflineCacheStatus
    let lastRefreshedAt: Date?
    let hasUsableSnapshot: Bool
    let item: PassItem

    var id: String { itemId }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.itemId == rhs.itemId && lhs.vaultId == rhs.vaultId && lhs.title == rhs.title
            && lhs.itemType == rhs.itemType && lhs.status == rhs.status
            && lhs.lastRefreshedAt == rhs.lastRefreshedAt
            && lhs.hasUsableSnapshot == rhs.hasUsableSnapshot
    }
}

nonisolated struct OfflineItemSettingsGroup: Sendable, Equatable, Identifiable {
    let vaultId: String
    let vaultName: String
    let items: [OfflineItemSettingsRow]

    var id: String { vaultId }
}

/// Service operations used by the metadata presentation coordinator.
nonisolated protocol OfflineModeServicing: OfflineInitializationProviding {
    func initialize() async throws
    func requiresInitializationRetry() async -> Bool
    func makeAvailableOffline(item: PassItem, shareId: String) async throws
    func removeOfflineItem(itemId: String) async throws
    func selectWholeVault(_ selected: Bool, vaultID: String) async throws
    func updateSelectionObservation(generation: UUID, status: OfflineSelectionObservationStatus) async
    func keepOfflineIndividually(_ item: PassItem) async throws
    func retrySelectedCopies(vaultID: String?) async throws
    func retryOfflineItem(itemID: String, vaultID: String) async throws -> OfflineItemRetryResult
    func metadataDidSynchronize(allowMembershipExpansion: Bool, eligibleItemIDs: Set<String>) async
    func waitUntilIdle() async
    func prepareForMetadataReset() async throws
    func finishMetadataReset() async
    func stop() async
    func removeAllOfflineData() async throws
}

nonisolated extension OfflineModeServicing {
    func retryOfflineItem(itemID: String, vaultID: String) async throws -> OfflineItemRetryResult { .unavailable }
}

/// Main-actor presentation state for host-only offline snapshot selections.
/// This coordinator retains availability metadata only; it never receives or
/// retains an offline secret snapshot.
@MainActor
@Observable
final class OfflineModeCoordinator {
    enum Error: LocalizedError {
        case missingCurrentVaultSelection
        case observationUnavailable
        case operationInProgress

        var errorDescription: String? {
            switch self {
            case .missingCurrentVaultSelection:
                String(localized: "The item is no longer available in the current vault catalog.")
            case .observationUnavailable:
                String(localized: "Offline status is unavailable. Retry offline setup before selecting new items.")
            case .operationInProgress:
                String(localized: "The offline selection changed or another operation is in progress. Retry offline status and try again.")
            }
        }
    }

    let service: any OfflineModeServicing
    let observation: any OfflineCatalogObserving
    private let shareIDForVault: @Sendable (String) -> String?
    var observationTask: Task<Void, Never>?
    var observationGeneration = UUID()
    var observationIsFresh = false
    private var snapshot = OfflinePresentationSnapshot.empty
    private var availabilityVaultIDByItemID: [String: String] = [:]
    private var itemOperationIDs: [String: UUID] = [:]
    private var itemMutationIDs: [String: UUID] = [:]
    private var vaultOperationIDs: [String: UUID] = [:]
    private var purgeOperationID: UUID?
    var onDetailSelectionInputsChanged: (@MainActor @Sendable () -> Void)?

    private(set) var vaults: [OfflineVaultSettingsRow] = []
    private(set) var itemGroups: [OfflineItemSettingsGroup] = []
    /// Indicates a non-secret startup-recovery failure. Removal and purge remain available.
    var requiresInitializationRetry = false
    /// A terminal observation error retains display rows but stops new selection until retry.
    var observationErrorMessage: String?

    var isPerformingTask: Bool {
        !itemOperationIDs.isEmpty || !vaultOperationIDs.isEmpty || purgeOperationID != nil
    }

    var canMakeNewSelections: Bool {
        observationIsFresh && !requiresInitializationRetry && observationErrorMessage == nil
    }

    init(
        service: any OfflineModeServicing,
        observation: any OfflineCatalogObserving,
        shareIDForVault: @escaping @Sendable (String) -> String?
    ) {
        self.service = service
        self.observation = observation
        self.shareIDForVault = shareIDForVault
    }

    /// Pure snapshot lookup; it never registers an item or performs I/O.
    func availability(for item: PassItem) -> OfflineItemAvailability {
        guard availabilityVaultIDByItemID[item.id] == item.vaultId else { return .notCached }
        return snapshot.availabilityByItemID[item.id] ?? .notCached
    }

    func isOperating(on item: PassItem) -> Bool {
        itemOperationIDs[item.id] != nil
    }

    /// Explicitly retries startup recovery and the terminated observation stream.
    @discardableResult
    func retryInitialization() async throws -> Task<Void, Never> {
        do {
            try await service.initialize()
            requiresInitializationRetry = false
            return retryObservation()
        } catch {
            let requiresRetry = await service.requiresInitializationRetry()
            guard !Task.isCancelled else { throw error }
            requiresInitializationRetry = requiresRetry
            observationIsFresh = false
            onDetailSelectionInputsChanged?()
            throw error
        }
    }

    func makeAvailableOffline(_ item: PassItem) async throws {
        guard canMakeNewSelections, itemOperationIDs[item.id] == nil else {
            if !canMakeNewSelections { throw Error.observationUnavailable }
            return
        }
        guard let shareID = shareIDForVault(item.vaultId), !shareID.isEmpty else {
            throw Error.missingCurrentVaultSelection
        }
        let operationID = UUID()
        itemOperationIDs[item.id] = operationID
        onDetailSelectionInputsChanged?()
        defer {
            if itemOperationIDs[item.id] == operationID {
                itemOperationIDs.removeValue(forKey: item.id)
                onDetailSelectionInputsChanged?()
            }
        }
        try await service.makeAvailableOffline(item: item, shareId: shareID)
        try Task.checkCancellation()
    }

    func removeOfflineItem(itemId: String) async throws {
        guard canRemoveItem(itemId) else { return }
        let operationID = UUID()
        itemMutationIDs[itemId] = operationID
        onDetailSelectionInputsChanged?()
        defer {
            if itemMutationIDs[itemId] == operationID {
                itemMutationIDs.removeValue(forKey: itemId)
                onDetailSelectionInputsChanged?()
            }
        }
        try await service.removeOfflineItem(itemId: itemId)
        try Task.checkCancellation()
    }

    func selectWholeVault(_ selected: Bool, vaultID: String) async throws {
        guard vaultOperationIDs[vaultID] == nil else { return }
        if selected && !canMakeNewSelections { throw Error.observationUnavailable }
        let operationID = UUID()
        vaultOperationIDs[vaultID] = operationID
        onDetailSelectionInputsChanged?()
        defer {
            if vaultOperationIDs[vaultID] == operationID {
                vaultOperationIDs.removeValue(forKey: vaultID)
                onDetailSelectionInputsChanged?()
            }
        }
        try await service.selectWholeVault(selected, vaultID: vaultID)
        try Task.checkCancellation()
    }

    func keepOfflineIndividually(_ item: PassItem) async throws {
        guard canMakeNewSelections else { throw Error.observationUnavailable }
        guard canKeepOfflineIndividually(item.id) else { throw Error.operationInProgress }
        let operationID = UUID()
        itemMutationIDs[item.id] = operationID
        onDetailSelectionInputsChanged?()
        defer {
            if itemMutationIDs[item.id] == operationID {
                itemMutationIDs.removeValue(forKey: item.id)
                onDetailSelectionInputsChanged?()
            }
        }
        try await service.keepOfflineIndividually(item)
        try Task.checkCancellation()
    }

    func retrySelectedCopies(vaultID: String?) async throws {
        guard canMakeNewSelections else { throw Error.observationUnavailable }
        try await service.retrySelectedCopies(vaultID: vaultID)
        try Task.checkCancellation()
    }

    func retryOfflineItem(itemID: String, vaultID: String) async throws -> OfflineItemRetryResult {
        guard canMakeNewSelections else { throw Error.observationUnavailable }
        let result = try await service.retryOfflineItem(itemID: itemID, vaultID: vaultID)
        try Task.checkCancellation()
        return result
    }

    func removeAllOfflineData() async throws {
        guard canPurge else { return }
        let operationID = UUID()
        purgeOperationID = operationID
        onDetailSelectionInputsChanged?()
        defer {
            if purgeOperationID == operationID {
                purgeOperationID = nil
                onDetailSelectionInputsChanged?()
            }
        }
        try await service.removeAllOfflineData()
        try Task.checkCancellation()
    }

    /// Whether vault policy can be revoked without conflicting with another mutation.
    func canDeselectVault(_ vaultID: String) -> Bool {
        guard snapshot.selectedVaultIDs.contains(vaultID),
              vaultOperationIDs[vaultID] == nil, purgeOperationID == nil else { return false }
        for (itemID, policy) in snapshot.policyByItemID {
            if policy.key.vaultId == vaultID && itemMutationIDs[itemID] != nil { return false }
        }
        return true
    }

    /// Whether the selected item can be removed without a conflicting item or purge mutation.
    func canRemoveItem(_ itemID: String) -> Bool {
        snapshot.policyByItemID[itemID] != nil
            && itemMutationIDs[itemID] == nil && purgeOperationID == nil
    }

    /// Whether a global purge can begin without racing another committed policy mutation.
    var canPurge: Bool {
        purgeOperationID == nil && vaultOperationIDs.isEmpty && itemMutationIDs.isEmpty
    }

    /// Whether current observed policy derives this item from a vault selection rather than manual intent.
    func shouldOfferKeepOfflineIndividually(_ itemID: String) -> Bool {
        guard let policy = snapshot.policyByItemID[itemID] else { return false }
        let hasUsableCopy: Bool
        switch snapshot.availabilityByItemID[itemID] {
        case .available?, .stale?: hasUsableCopy = true
        default: hasUsableCopy = false
        }
        return hasUsableCopy && !policy.isManuallySelected && !policy.isExcluded && policy.vaultSelection != nil
    }

    /// Whether current observed vault-derived selection may be promoted without secret work.
    func canKeepOfflineIndividually(_ itemID: String) -> Bool {
        guard canMakeNewSelections,
              itemOperationIDs[itemID] == nil,
              itemMutationIDs[itemID] == nil,
              let policy = snapshot.policyByItemID[itemID],
              vaultOperationIDs[policy.key.vaultId] == nil,
              purgeOperationID == nil else { return false }
        return !policy.isManuallySelected && !policy.isExcluded && policy.vaultSelection != nil
    }

    /// Consumes one metadata emission from the owned observation stream.
    func apply(_ presentation: OfflinePresentationSnapshot) {
        snapshot = presentation
        vaults = presentation.vaults
        itemGroups = presentation.itemGroups
        availabilityVaultIDByItemID = Dictionary(
            uniqueKeysWithValues: presentation.itemGroups.flatMap(\.items).map { ($0.itemId, $0.vaultId) }
        )
        onDetailSelectionInputsChanged?()
    }
}
