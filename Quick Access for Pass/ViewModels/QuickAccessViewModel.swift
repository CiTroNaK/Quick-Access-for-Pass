import SwiftUI
import Observation

/// Async closure that fetches a fully-decoded item from pass-cli. Injected into
/// `QuickAccessViewModel` so tests can stub the secret-bearing call.
typealias CLIItemFetcher = @Sendable (_ itemId: String, _ shareId: String) async throws -> CLIItem
typealias LargeTypePresenter = @MainActor @Sendable (LargeTypeDisplay) -> Void

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
    let fetchItem: CLIItemFetcher
    let presentLargeType: LargeTypePresenter
    private var searchTask: Task<Void, Never>?
    private var clearSearchTask: Task<Void, Never>?
    var inFlightCopy: Task<Void, Never>?
    var inFlightLargeType: Task<Void, Never>?
    var copyGeneration = 0
    var largeTypeGeneration = 0

    init(
        searchService: SearchService,
        cliService: PassCLIService,
        clipboardManager: ClipboardManager,
        onDismiss: @escaping () -> Void,
        onActivity: @escaping () -> Void = {},
        defaults: UserDefaults = .standard,
        fetchItem: CLIItemFetcher? = nil,
        presentLargeType: LargeTypePresenter? = nil
    ) {
        self.searchService = searchService
        self.cliService = cliService
        self.clipboardManager = clipboardManager
        self.onDismiss = onDismiss
        self.onActivity = onActivity
        self.defaults = defaults
        self.cliPath = cliService.cliPath
        self.presentLargeType = presentLargeType ?? { _ in }
        if let fetchItem {
            self.fetchItem = fetchItem
        } else {
            self.fetchItem = { itemId, shareId in
                try await cliService.viewItem(itemId: itemId, shareId: shareId)
            }
        }
    }

    // MARK: - Vault Name

    func vaultName(for vaultId: String) -> String {
        (try? searchService.vaultName(for: vaultId)) ?? ""
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
        }
    }

    func cancelSearchClear() {
        clearSearchTask?.cancel()
        clearSearchTask = nil
    }

    #if DEBUG
    /// Awaits the in-flight search-clear task, if any. Test-only — available
    /// only in Debug builds to avoid exposing it as production API.
    func awaitPendingSearchClear() async {
        await clearSearchTask?.value
    }
    #endif

    // MARK: - Navigation

    func showDetail() {
        onActivity()
        guard let item = items[safe: selectedIndex] else { return }
        detailItem = item
        selectedRowIndex = 0
    }

    func hideDetail() {
        onActivity()
        inFlightCopy?.cancel()
        inFlightCopy = nil
        inFlightLargeType?.cancel()
        inFlightLargeType = nil
        isActionLoading = false
        copyGeneration += 1
        largeTypeGeneration += 1
        detailItem = nil
        selectedRowIndex = 0
    }

    func moveRowSelection(by offset: Int) {
        onActivity()
        guard let item = detailItem else { return }
        let rows = rows(for: item)
        guard !rows.isEmpty else { return }

        let proposed = max(0, min(rows.count - 1, selectedRowIndex + offset))
        let direction = offset >= 0 ? 1 : -1
        var index = proposed
        while index >= 0 && index < rows.count && !rows[index].isSelectable {
            let next = index + direction
            if next < 0 || next >= rows.count { break }
            index = next
        }
        if index >= 0 && index < rows.count && rows[index].isSelectable {
            selectedRowIndex = index
        }
    }

    // MARK: - Selection

    func moveSelection(by offset: Int) {
        onActivity()
        guard !items.isEmpty else { return }
        selectedIndex = max(0, min(items.count - 1, selectedIndex + offset))
    }

    // MARK: - Row Model

    /// Unified list of detail rows: today's named actions (top group) followed
    /// by the field rows derived from `item.fieldKeys`. Section-header row
    /// identity includes the header's ordinal position so two sections that
    /// happen to share a name produce distinct IDs for diffing/scroll targeting.
    func rows(for item: PassItem) -> [DetailRow] {
        var rows: [DetailRow] = actionsForItem(item).map { tuple in
            .namedAction(action: tuple.action, label: tuple.label, shortcut: tuple.shortcut)
        }
        var sectionOrdinal = 0
        for key in item.fieldKeys {
            switch key {
            case .sectionHeader(let name):
                rows.append(.sectionHeader(name: name, id: "\(sectionOrdinal):\(name)"))
                sectionOrdinal += 1
            default:
                rows.append(.field(key: key, label: key.localizedLabel, isSensitive: key.isSensitive))
            }
        }
        return rows
    }

    // MARK: - Keyboard Shortcut Handling

    /// Called by the local NSEvent monitor in PanelController. Returns `true` if the event
    /// matched a configured copy shortcut and was handled.
    func handleKeyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        let item = detailItem ?? items[safe: selectedIndex]
        guard let item else { return false }

        let largeTypeCode = UInt16(defaults.integer(forKey: DefaultsKey.showLargeTypeKeyCode))
        let largeTypeMods = NSEvent.ModifierFlags(
            rawValue: UInt(defaults.integer(forKey: DefaultsKey.showLargeTypeModifiers))
        ).intersection([.command, .shift, .option, .control])
        if detailItem != nil, keyCode == largeTypeCode, modifiers == largeTypeMods {
            onActivity()
            showSelectedRowInLargeType()
            return true
        }

        let shortcuts: [(codeKey: String, modsKey: String, action: ItemAction)] = [
            (DefaultsKey.copyUsernameKeyCode, DefaultsKey.copyUsernameModifiers, .copyUsername),
            (DefaultsKey.copyPasswordKeyCode, DefaultsKey.copyPasswordModifiers, .copyPassword),
            (DefaultsKey.copyTotpKeyCode, DefaultsKey.copyTotpModifiers, .copyTotp),
        ]

        for shortcut in shortcuts {
            let storedCode = UInt16(defaults.integer(forKey: shortcut.codeKey))
            let storedMods = NSEvent.ModifierFlags(
                rawValue: UInt(defaults.integer(forKey: shortcut.modsKey))
            ).intersection([.command, .shift, .option, .control])
            let action = shortcut.action
            if keyCode == storedCode && modifiers == storedMods {
                onActivity()
                if detailItem != nil {
                    let rows = rows(for: item)
                    if let index = rows.firstIndex(where: {
                        if case .namedAction(let current, _, _) = $0 { return current == action }
                        return false
                    }) {
                        selectedRowIndex = index
                    }
                }
                handleAction(action, for: item)
                return true
            }
        }
        return false
    }

    // MARK: - Actions

    func handleEnter() {
        onActivity()
        if let item = detailItem {
            let rows = rows(for: item)
            guard let row = rows[safe: selectedRowIndex], row.isSelectable else { return }
            switch row {
            case .namedAction(let action, _, _):
                handleAction(action, for: item)
            case .field(let key, _, _):
                copyField(key, from: item)
            case .sectionHeader:
                return
            }
        } else {
            guard let item = items[safe: selectedIndex] else { return }
            handleAction(defaultAction(for: item.itemType), for: item)
        }
    }
}
