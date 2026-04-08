import AppKit

@MainActor
final class SyncCoordinator {
    private let cliService: PassCLIService
    private let databaseManager: DatabaseManager
    private weak var viewModel: QuickAccessViewModel?

    private var syncTask: Task<Void, Never>?
    private var syncTimer: Timer?
    private var currentSyncInterval: TimeInterval = 0

    init(cliService: PassCLIService, databaseManager: DatabaseManager, viewModel: QuickAccessViewModel) {
        self.cliService = cliService
        self.databaseManager = databaseManager
        self.viewModel = viewModel
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

            do {
                let (vaults, cliItems) = try await cliService.fetchAllItems()
                let passVaults = vaults.map { PassVault(from: $0) }
                let passItems = cliItems.map { PassItem(from: $0.item, vaultId: $0.vaultId) }

                let db = databaseManager
                try await Task.detached {
                    try db.upsertVaults(passVaults)
                    try db.syncItems(passItems)
                }.value

                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: DefaultsKey.lastSyncTime)
                viewModel.performSearch(query: viewModel.searchQuery)
            } catch let error as CLIError where error.isNotInstalled {
                viewModel.errorMessage = String(localized: "pass-cli not found. Install: brew install protonpass/tap/pass-cli")
            } catch let error as CLIError where error.isAuthError {
                viewModel.errorMessage = String(localized: "Not logged in. Run: pass-cli login")
            } catch {
                viewModel.errorMessage = String(localized: "Sync failed: \(error.localizedDescription)")
            }
        }
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
            viewModel?.errorMessage = String(localized: "Failed to reset database: \(error.localizedDescription)")
            return
        }
        refreshNow()
    }

    // MARK: - Private

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
