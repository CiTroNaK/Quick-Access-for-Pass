import AppKit
import os

@MainActor
final class SyncCoordinator {
    private let cliService: PassCLIService
    let databaseManager: DatabaseManager
    let identitySynchronizer: any AutoFillIdentitySynchronizing
    let offlineModeService: OfflineModeService?
    /// Shared metadata-only remnant maintenance; it does not affect sync success.
    let maintenance: OfflineStorageMaintenance?
    private let onResetInitiated: @MainActor @Sendable () -> Void
    private weak var viewModel: QuickAccessViewModel?
    private let onSyncIssueChanged: @MainActor @Sendable (QuickAccessSyncIssuePresentation?) -> Void
    private let onAuthenticationRequired: (@MainActor @Sendable (PassCLIHealth) async -> Void)?
    private let defaults: UserDefaults

    private var syncTask: Task<Void, Never>?
    /// Snapshot of actual completion for metadata-only lifecycle coordination.
    var currentSyncCompletion: Task<Void, Never>? { syncTask }
    private var resetTask: Task<Void, Never>?
    private var syncTimer: Timer?
    private var currentSyncInterval: TimeInterval = 0

    init(
        cliService: PassCLIService,
        databaseManager: DatabaseManager,
        viewModel: QuickAccessViewModel,
        identitySynchronizer: any AutoFillIdentitySynchronizing = DisabledAutoFillIdentitySynchronizer(),
        offlineModeService: OfflineModeService? = nil,
        maintenance: OfflineStorageMaintenance? = nil,
        onResetInitiated: @escaping @MainActor @Sendable () -> Void = {},
        onSyncIssueChanged: @escaping @MainActor @Sendable (QuickAccessSyncIssuePresentation?) -> Void = { _ in },
        onAuthenticationRequired: (@MainActor @Sendable (PassCLIHealth) async -> Void)? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        self.cliService = cliService
        self.databaseManager = databaseManager
        self.identitySynchronizer = identitySynchronizer
        self.offlineModeService = offlineModeService
        self.maintenance = maintenance
        self.onResetInitiated = onResetInitiated
        self.viewModel = viewModel
        self.onSyncIssueChanged = onSyncIssueChanged
        self.onAuthenticationRequired = onAuthenticationRequired
    }

    // MARK: - Public

    func start() {
        refreshNow()
        scheduleSyncTimer()
    }

    func refreshNow() {
        guard resetTask == nil, let viewModel else { return }

        let operation = databaseManager.beginSyncOperation()
        syncTask?.cancel()
        syncTask = Task {
            guard operation.isCurrent, !Task.isCancelled else { return }
            viewModel.isLoading = true
            defer {
                if operation.isCurrent { viewModel.isLoading = false }
            }
            await performSync(operation: operation, viewModel: viewModel)
        }
    }

    private func performSync(operation: SyncOperationToken, viewModel: QuickAccessViewModel) async {
        let capture = await offlineModeService?.captureForSync(operation: operation)
        if operation.isCurrent, !Task.isCancelled {
            await performCapturedSync(operation: operation, viewModel: viewModel, capture: capture)
        }
        // Explicitly joined on every return/error path, including cancelled native work.
        if let capture { await offlineModeService?.finishSyncCapture(capture) }
    }

    private func performCapturedSync(operation: SyncOperationToken, viewModel: QuickAccessViewModel, capture: OfflineSyncCapture?) async {
        var skippedItemsForDiagnostics: [SkippedSyncItem] = []
        var skippedDiagnosticFileURL: URL?
        do {
            let fetchResult = try await cliService.fetchAllItems { progress in
                await MainActor.run {
                    guard operation.isCurrent else { return }
                    viewModel.syncProgress = progress
                }
            }
            try requireCurrentSync(operation)
            let skippedItems = fetchResult.skippedItems
            skippedItemsForDiagnostics = skippedItems
            if !skippedItems.isEmpty {
                AppLogger.sync.warning("sync completed with \(skippedItems.count, privacy: .public) skipped item(s)")
                skippedDiagnosticFileURL = Self.writeSkippedItemDiagnostics(skippedItems)
                for skipped in skippedItems.prefix(20) {
                    AppLogger.sync.warning("skipped sync item: \(skipped.diagnosticSummary, privacy: .private(mask: .hash))")
                }
            }
            try await synchronizeFetchedMetadata(fetchResult, operation: operation, capture: capture)
            try requireCurrentSync(operation)
            finishSuccessfulSync(
                skippedItems: skippedItems,
                diagnosticFileURL: skippedDiagnosticFileURL,
                viewModel: viewModel, operation: operation
            )
        } catch is CancellationError {
            return
        } catch let error as CLIError where error.isNotInstalled {
            guard operation.isCurrent, !Task.isCancelled else { return }
            viewModel.syncProgress = nil
            viewModel.syncError = nil
            viewModel.skippedSyncItems = nil
            viewModel.isShowingSkippedSyncItems = false
            viewModel.errorMessage = String(localized: "pass-cli not found. Install: brew install protonpass/tap/pass-cli")
            onSyncIssueChanged(nil)
        } catch let error as CLIError where error.isAuthError {
            await handleAuthSyncError(error, viewModel: viewModel, operation: operation)
        } catch {
            guard operation.isCurrent, !Task.isCancelled else { return }
            viewModel.errorMessage = nil
            viewModel.syncProgress = nil
            viewModel.isShowingSkippedSyncItems = false
            let presentation = Self.syncErrorPresentation(
                for: error,
                cliSelection: cliService.cliSelection,
                skippedItems: skippedItemsForDiagnostics,
                diagnosticFileURL: skippedDiagnosticFileURL
            )
            viewModel.syncError = presentation
            onSyncIssueChanged(.syncError(presentation))
        }
    }

    private func handleAuthSyncError(_ error: CLIError, viewModel: QuickAccessViewModel, operation: SyncOperationToken) async {
        guard operation.isCurrent, !Task.isCancelled else { return }
        viewModel.errorMessage = nil
        viewModel.isShowingSkippedSyncItems = false
        if let onAuthenticationRequired {
            // Recovery owns the auth presentation. Do not flash Login before checking
            // the PAT, or overwrite progress / Update PAT from an existing attempt.
            if viewModel.syncError?.action == .copyAndReport {
                viewModel.syncError = nil
            }
            let health: PassCLIHealth = error.isLocalSessionDecryptionError ? .localSessionUnreadable : .notLoggedIn
            await onAuthenticationRequired(health)
        } else {
            viewModel.syncProgress = nil
            if viewModel.syncError?.action != .updatePAT {
                viewModel.syncError = Self.syncErrorPresentation(for: error, cliSelection: cliService.cliSelection)
            }
        }
        guard operation.isCurrent, !Task.isCancelled else { return }
        onSyncIssueChanged(nil)
    }

    func reloadTimerIfNeeded() {
        let interval = clampedSyncInterval()
        if interval != currentSyncInterval {
            scheduleSyncTimer()
        }
    }

    func resetAndSync() {
        // Keep one reset owner so stale task cleanup cannot release a newer reset barrier.
        guard resetTask == nil else { return }
        databaseManager.invalidateSyncOperations()
        onResetInitiated()
        syncTask?.cancel()
        syncTask = nil
        viewModel?.isLoading = true
        resetTask = Task { [weak self] in
            guard let self else { return }
            var resetError: (any Error)?
            var resetOperation: SyncOperationToken?
            do {
                try await offlineModeService?.prepareForMetadataReset()
                try Task.checkCancellation()
                try await databaseManager.clearMetadata()
                let operation = databaseManager.beginSyncOperation()
                resetOperation = operation
                let descriptors = try databaseManager.allAutoFillDescriptors()
                try await identitySynchronizer.reconcile(descriptors: descriptors, isCurrent: { operation.isCurrent })
                try requireCurrentSync(operation)
            } catch {
                resetError = error
            }
            await offlineModeService?.finishMetadataReset()
            resetTask = nil
            guard resetOperation?.isCurrent != false else { return }
            if Task.isCancelled { resetError = CancellationError() }
            if let resetError {
                viewModel?.isLoading = false
                if !(resetError is CancellationError) {
                    viewModel?.syncError = nil
                    viewModel?.errorMessage = String(localized: "Failed to reset database: \(resetError.localizedDescription)")
                }
            } else {
                refreshNow()
            }
        }
    }

    nonisolated private static func writeSkippedItemDiagnostics(_ skippedItems: [SkippedSyncItem]) -> URL? {
        do {
            let url = try SyncDiagnosticFileStore.writeSkippedItems(skippedItems)
            if let url {
                AppLogger.sync.warning("wrote skipped sync item diagnostics to \(url.path, privacy: .private(mask: .hash))")
            }
            return url
        } catch {
            AppLogger.sync.warning("failed to write skipped sync item diagnostics: \(error.localizedDescription, privacy: .private(mask: .hash))")
            return nil
        }
    }

    // MARK: - Private

    private func finishSuccessfulSync(
        skippedItems: [SkippedSyncItem],
        diagnosticFileURL: URL?,
        viewModel: QuickAccessViewModel,
        operation: SyncOperationToken
    ) {
        guard operation.isCurrent, !Task.isCancelled else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: DefaultsKey.lastSyncTime)
        viewModel.syncError = nil
        if skippedItems.isEmpty {
            viewModel.syncProgress = nil
            viewModel.skippedSyncItems = nil
            viewModel.isShowingSkippedSyncItems = false
        } else {
            viewModel.syncProgress = .completedWithSkippedItems(skippedItems.count)
            viewModel.skippedSyncItems = SyncSkippedItemsPresentation.make(
                skippedItems: skippedItems,
                diagnosticFileURL: diagnosticFileURL
            )
        }
        if let skippedSyncItems = viewModel.skippedSyncItems {
            onSyncIssueChanged(.skippedItems(skippedSyncItems))
        } else {
            onSyncIssueChanged(nil)
        }
        guard operation.isCurrent, !Task.isCancelled else { return }
        viewModel.performSearch(query: viewModel.searchQuery)
    }

    private func clampedSyncInterval() -> TimeInterval {
        let interval = defaults.double(forKey: DefaultsKey.syncInterval)
        return interval >= 60 ? interval : 300
    }

    private func scheduleSyncTimer() {
        syncTimer?.invalidate()
        let interval = clampedSyncInterval()
        currentSyncInterval = interval
        syncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshNow()
            }
        }
    }
}
