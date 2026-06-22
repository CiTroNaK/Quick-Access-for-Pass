import AppKit
import os

@MainActor
final class SyncCoordinator {
    private let cliService: PassCLIService
    private let databaseManager: DatabaseManager
    private weak var viewModel: QuickAccessViewModel?
    private let onSyncIssueChanged: @MainActor @Sendable (QuickAccessSyncIssuePresentation?) -> Void

    private var syncTask: Task<Void, Never>?
    private var syncTimer: Timer?
    private var currentSyncInterval: TimeInterval = 0

    init(
        cliService: PassCLIService,
        databaseManager: DatabaseManager,
        viewModel: QuickAccessViewModel,
        onSyncIssueChanged: @escaping @MainActor @Sendable (QuickAccessSyncIssuePresentation?) -> Void = { _ in }
    ) {
        self.cliService = cliService
        self.databaseManager = databaseManager
        self.viewModel = viewModel
        self.onSyncIssueChanged = onSyncIssueChanged
    }

    // MARK: - Public

    func start() {
        refreshNow()
        scheduleSyncTimer()
    }

    func refreshNow() {
        guard let viewModel else { return }

        syncTask?.cancel()
        syncTask = Task {
            viewModel.isLoading = true
            defer { viewModel.isLoading = false }
            var skippedItemsForDiagnostics: [SkippedSyncItem] = []
            var skippedDiagnosticFileURL: URL?

            do {
                let (vaults, cliItems, skippedItems) = try await cliService.fetchAllItems { [weak viewModel] progress in
                    await MainActor.run {
                        viewModel?.syncProgress = progress
                    }
                }
                skippedItemsForDiagnostics = skippedItems
                if !skippedItems.isEmpty {
                    AppLogger.sync.warning("sync completed with \(skippedItems.count, privacy: .public) skipped item(s)")
                    skippedDiagnosticFileURL = Self.writeSkippedItemDiagnostics(skippedItems)
                    for skipped in skippedItems.prefix(20) {
                        AppLogger.sync.warning("skipped sync item: \(skipped.diagnosticSummary, privacy: .private(mask: .hash))")
                    }
                }
                let passVaults = vaults.map { PassVault(from: $0) }
                let passItems = cliItems.map { PassItem(from: $0.item, vaultId: $0.vaultId) }
                let currentVaultIds = Set(passVaults.map(\.id))

                let db = databaseManager
                try await Task.detached {
                    try db.upsertVaults(passVaults)
                    try db.syncItems(passItems)
                    try db.removeVaultsNotIn(currentVaultIds)
                }.value

                finishSuccessfulSync(
                    skippedItems: skippedItems,
                    diagnosticFileURL: skippedDiagnosticFileURL,
                    viewModel: viewModel
                )
            } catch let error as CLIError where error.isNotInstalled {
                viewModel.syncProgress = nil
                viewModel.syncError = nil
                viewModel.skippedSyncItems = nil
                viewModel.isShowingSkippedSyncItems = false
                viewModel.errorMessage = String(localized: "pass-cli not found. Install: brew install protonpass/tap/pass-cli")
                onSyncIssueChanged(nil)
            } catch let error as CLIError where error.isAuthError {
                handleAuthSyncError(error, viewModel: viewModel)
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

    private func handleAuthSyncError(_ error: CLIError, viewModel: QuickAccessViewModel) {
        viewModel.errorMessage = nil
        viewModel.syncProgress = nil
        viewModel.isShowingSkippedSyncItems = false
        if viewModel.syncError?.action != .updatePAT {
            viewModel.syncError = Self.syncErrorPresentation(for: error, cliSelection: cliService.cliSelection)
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
        do {
            try databaseManager.clearAll()
        } catch {
            viewModel?.syncError = nil
            viewModel?.errorMessage = String(localized: "Failed to reset database: \(error.localizedDescription)")
            return
        }
        refreshNow()
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
