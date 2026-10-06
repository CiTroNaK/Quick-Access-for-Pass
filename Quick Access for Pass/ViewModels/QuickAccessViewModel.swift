import AppKit
import SwiftUI
import Observation

typealias LargeTypePresenter = @MainActor @Sendable (LargeTypeDisplay) -> Void
typealias PasteboardStringWriter = @MainActor @Sendable (String) -> Void
typealias URLOpener = @MainActor @Sendable (URL) -> Bool

@MainActor
@Observable
final class QuickAccessViewModel {
    var searchQuery = "" {
        didSet { scheduleSearch() }
    }
    private(set) var items: [PassItem] = []
    var selectedIndex = 0
    var isLoading = false
    var isActionLoading = false
    var errorMessage: String?
    var syncError: SyncErrorPresentation?
    var syncProgress: SyncProgressPresentation?
    var skippedSyncItems: SyncSkippedItemsPresentation?
    var isShowingSkippedSyncItems = false
    var detailItem: PassItem?
    var selectedRowIndex = 0
    private(set) var cliPath: String = ""
    var lastCommand: String = ""

    let searchService: SearchService
    let cliService: PassCLIService
    let clipboardManager: ClipboardManager
    let onDismiss: () -> Void
    let onActivity: () -> Void
    let defaults: UserDefaults
    let secretResolver: any SecretItemResolving
    let offlineModeCoordinator: OfflineModeCoordinator?
    let secretReleaseGuard: SecretReleaseGuard
    let presentLargeType: LargeTypePresenter
    let writeStringToPasteboard: PasteboardStringWriter
    let openURL: URLOpener
    private var searchTask: Task<Void, Never>?
    private var clearSearchTask: Task<Void, Never>?
    var inFlightCopy: Task<Void, Never>?
    var inFlightLargeType: Task<Void, Never>?
    var inFlightOfflineOperation: Task<Void, Never>?
    var copyGeneration = 0
    var largeTypeGeneration = 0
    var offlineOperationGeneration = 0

    init(
        searchService: SearchService,
        cliService: PassCLIService,
        clipboardManager: ClipboardManager,
        onDismiss: @escaping () -> Void,
        onActivity: @escaping () -> Void = {},
        defaults: UserDefaults = .standard,
        secretResolver: (any SecretItemResolving)? = nil,
        offlineModeCoordinator: OfflineModeCoordinator? = nil,
        secretReleaseGuard: SecretReleaseGuard = SecretReleaseGuard(),
        fetchItem: CLIItemFetcher? = nil,
        presentLargeType: LargeTypePresenter? = nil,
        writeStringToPasteboard: @escaping PasteboardStringWriter = { value in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        },
        openURL: @escaping URLOpener = { url in
            NSWorkspace.shared.open(url)
        }
    ) {
        self.searchService = searchService
        self.cliService = cliService
        self.clipboardManager = clipboardManager
        self.onDismiss = onDismiss
        self.onActivity = onActivity
        self.defaults = defaults
        self.cliPath = cliService.cliPath
        self.offlineModeCoordinator = offlineModeCoordinator
        self.secretReleaseGuard = secretReleaseGuard
        self.presentLargeType = presentLargeType ?? { _ in }
        self.writeStringToPasteboard = writeStringToPasteboard
        self.openURL = openURL
        if let secretResolver {
            self.secretResolver = secretResolver
        } else if let fetchItem {
            self.secretResolver = LegacySecretItemResolver(fetchItem: fetchItem, cliService: cliService)
        } else {
            self.secretResolver = LiveSecretItemResolver(cliService: cliService)
        }
    }

    // MARK: - Search

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            performSearch(query: searchQuery)
        }
    }

    func performSearch(query: String) {
        detailItem = nil
        isShowingSkippedSyncItems = false
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            items = []
            selectedIndex = 0
            errorMessage = nil
            return
        }
        do {
            items = try searchService.search(query: query)
            selectedIndex = 0
            errorMessage = nil
        } catch {
            syncError = nil
            syncProgress = nil
            skippedSyncItems = nil
            isShowingSkippedSyncItems = false
            errorMessage = error.localizedDescription
        }
    }

    func scheduleSearchClear() {
        clearSearchTask?.cancel()
        let timeout = defaults.double(forKey: DefaultsKey.searchClearTimeout)
        guard timeout > 0 else { return }
        clearSearchTask = Task {
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            searchQuery = ""
            errorMessage = nil
            syncError = nil
            syncProgress = nil
            skippedSyncItems = nil
            isShowingSkippedSyncItems = false
        }
    }

    func cancelSearchClear() {
        clearSearchTask?.cancel()
        clearSearchTask = nil
    }

    func clearForLock() {
        clearSearchTask?.cancel()
        clearSearchTask = nil
        cancelSecretActions()
        inFlightOfflineOperation?.cancel()
        inFlightOfflineOperation = nil

        searchQuery = ""
        searchTask?.cancel()
        searchTask = nil

        items = []
        selectedIndex = 0
        selectedRowIndex = 0
        detailItem = nil
        errorMessage = nil
        syncError = nil
        syncProgress = nil
        skippedSyncItems = nil
        isShowingSkippedSyncItems = false
        isLoading = false
        offlineOperationGeneration += 1
    }

    /// Cancels only view-model-owned secret action tasks and advances their
    /// release generations. Search and offline maintenance remain untouched.
    func cancelSecretActions() {
        inFlightCopy?.cancel()
        inFlightCopy = nil
        inFlightLargeType?.cancel()
        inFlightLargeType = nil
        isActionLoading = false
        copyGeneration += 1
        largeTypeGeneration += 1
    }

    #if DEBUG
    /// Awaits the in-flight search-clear task, if any. Test-only — available
    /// only in Debug builds to avoid exposing it as production API.
    func awaitPendingSearchClear() async {
        await clearSearchTask?.value
    }
    #endif

    // MARK: - Actions

    func handleEnter() {
        onActivity()
        if let item = detailItem {
            let rows = rows(for: item)
            guard let row = rows[safe: selectedRowIndex], isDetailRowSelectable(row, for: item) else { return }
            switch row {
            case .namedAction(let action, _, _):
                handleAction(action, for: item)
            case .field(let key, _, _):
                copyField(key, from: item)
            case .offlineAvailability:
                handleOfflineAvailability(for: item)
            case .keepOfflineIndividually:
                handleKeepOfflineIndividually(for: item)
            case .sectionHeader:
                return
            }
        } else {
            guard let item = items[safe: selectedIndex] else { return }
            handleAction(defaultAction(for: item.itemType), for: item)
        }
    }
}
