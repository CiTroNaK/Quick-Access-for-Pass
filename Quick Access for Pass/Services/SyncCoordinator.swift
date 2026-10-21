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

    private var syncTask: Task<Void, Never>?
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
        onAuthenticationRequired: (@MainActor @Sendable (PassCLIHealth) async -> Void)? = nil
    ) {
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

        syncTask?.cancel()
        syncTask = Task {
            viewModel.isLoading = true
            defer { viewModel.isLoading = false }
            var skippedItemsForDiagnostics: [SkippedSyncItem] = []
            var skippedDiagnosticFileURL: URL?

            do {
                let fetchResult = try await cliService.fetchAllItems { progress in
                    await MainActor.run {
                        viewModel.syncProgress = progress
                    }
                }
                let skippedItems = fetchResult.skippedItems
                skippedItemsForDiagnostics = skippedItems
                if !skippedItems.isEmpty {
                    AppLogger.sync.warning("sync completed with \(skippedItems.count, privacy: .public) skipped item(s)")
                    skippedDiagnosticFileURL = Self.writeSkippedItemDiagnostics(skippedItems)
                    for skipped in skippedItems.prefix(20) {
                        AppLogger.sync.warning("skipped sync item: \(skipped.diagnosticSummary, privacy: .private(mask: .hash))")
                    }
                }
                try await synchronizeFetchedMetadata(fetchResult)

                finishSuccessfulSync(
                    skippedItems: skippedItems,
                    diagnosticFileURL: skippedDiagnosticFileURL,
                    viewModel: viewModel
                )
            } catch is CancellationError {
                return
            } catch let error as CLIError where error.isNotInstalled {
                viewModel.syncProgress = nil
                viewModel.syncError = nil
                viewModel.skippedSyncItems = nil
                viewModel.isShowingSkippedSyncItems = false
                viewModel.errorMessage = String(localized: "pass-cli not found. Install: brew install protonpass/tap/pass-cli")
                onSyncIssueChanged(nil)
            } catch let error as CLIError where error.isAuthError {
                await handleAuthSyncError(error, viewModel: viewModel)
            } catch {
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
    }

    private func handleAuthSyncError(_ error: CLIError, viewModel: QuickAccessViewModel) async {
        guard !Task.isCancelled else { return }
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
        onResetInitiated()
        syncTask?.cancel()
        syncTask = nil
        resetTask = Task { [weak self] in
            guard let self else { return }
            guard let offlineModeService else {
                do {
                    try await databaseManager.clearMetadata()
                    resetTask = nil
                    refreshNow()
                } catch is CancellationError {
                    resetTask = nil
                } catch {
                    viewModel?.syncError = nil
                    viewModel?.errorMessage = String(localized: "Failed to reset database: \(error.localizedDescription)")
                    resetTask = nil
                }
                return
            }

            do {
                try await offlineModeService.prepareForMetadataReset()
                try Task.checkCancellation()
                try await databaseManager.clearMetadata()
                await offlineModeService.finishMetadataReset()
                resetTask = nil
                refreshNow()
            } catch is CancellationError {
                await offlineModeService.finishMetadataReset()
                resetTask = nil
            } catch {
                await offlineModeService.finishMetadataReset()
                viewModel?.syncError = nil
                viewModel?.errorMessage = String(localized: "Failed to reset database: \(error.localizedDescription)")
                resetTask = nil
            }
        }
    }

    nonisolated static func syncErrorPresentation(
        for error: Error,
        cliSelection: PassCLISelection,
        skippedItems: [SkippedSyncItem] = [],
        diagnosticFileURL: URL? = nil
    ) -> SyncErrorPresentation {
        if let cliError = error as? CLIError, cliError.isAuthError {
            return .loginRequired()
        }

        return .genericFailure(
            diagnosticReport: SyncErrorDiagnosticReport.make(
                error: error,
                cliSelection: cliSelection,
                skippedItems: skippedItems,
                diagnosticFileURL: diagnosticFileURL
            )
        )
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
        viewModel: QuickAccessViewModel
    ) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: DefaultsKey.lastSyncTime)
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
        viewModel.performSearch(query: viewModel.searchQuery)
    }

    private func clampedSyncInterval() -> TimeInterval {
        let interval = UserDefaults.standard.double(forKey: DefaultsKey.syncInterval)
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
