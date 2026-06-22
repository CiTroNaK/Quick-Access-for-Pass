import SwiftUI
import Accessibility

// MARK: - Liquid Glass compatibility wrappers
// Using `if #available` inside @ViewBuilder satisfies the compiler without
// requiring @available annotations on every caller. This app requires macOS 26
// (enforced by LSMinimumSystemVersion), so the else branches are never reached.
extension View {
    @ViewBuilder
    func appGlassEffect(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
        }
    }

    @ViewBuilder
    func appCircleGlassEffect() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(in: Circle())
        } else {
            self
        }
    }

    @ViewBuilder
    func appCapsuleGlassEffect() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(in: Capsule())
        } else {
            self
        }
    }

    func appGlassBackground(cornerRadius: CGFloat) -> some View {
        self
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    @ViewBuilder
    func appClearGlassButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass(.clear))
        } else {
            self.buttonStyle(.borderless)
        }
    }
}

struct QuickAccessView: View {
    @Bindable var viewModel: QuickAccessViewModel
    let onDismiss: () -> Void
    let appDelegate: AppDelegate
    @Environment(\.openSettings) private var openSettings
    @FocusState private var isSearchFocused: Bool

    private var hotkeyLabel: String {
        let code = UserDefaults.standard.integer(forKey: DefaultsKey.hotkeyCode)
        let mods = UserDefaults.standard.integer(forKey: DefaultsKey.hotkeyModifiers)
        if code > 0 && mods > 0 {
            return ShortcutFormatting.label(keyCode: code, modifiers: mods)
        }
        return "⇧⌥Space"
    }

    private var contentState: QuickAccessViewContentState {
        QuickAccessViewContentState.resolve(QuickAccessViewContentInputs(
            isLocked: appDelegate.isLocked,
            hasDetailItem: viewModel.detailItem != nil,
            hasItems: !viewModel.items.isEmpty,
            hasSyncError: viewModel.syncError != nil,
            hasSkippedItemDetails: viewModel.isShowingSkippedSyncItems && viewModel.skippedSyncItems != nil,
            hasErrorMessage: viewModel.errorMessage != nil,
            searchQuery: viewModel.searchQuery
        ))
    }

    private var hasItemContent: Bool {
        contentState == .itemContent
    }

    private var hasEmptyState: Bool {
        switch contentState {
        case .errorMessage, .noResults:
            true
        case .locked, .syncError, .itemContent, .skippedItemDetails, .shortcuts:
            false
        }
    }

    var syncIssueTrailingItem: QuickAccessFooterItem? {
        QuickAccessFooterContent.syncIssueTrailingItem(
            syncError: viewModel.syncError,
            hasSkippedItems: viewModel.skippedSyncItems != nil
        )
    }

    private var emptyStateFooter: some View {
        QuickAccessShortcutHints(
            hotkeyLabel: hotkeyLabel,
            isLoading: viewModel.isLoading,
            hasItems: !viewModel.items.isEmpty,
            searchQuery: viewModel.searchQuery,
            syncProgress: viewModel.syncProgress,
            hasSkippedItems: viewModel.skippedSyncItems != nil,
            syncIssueTrailingItem: syncIssueTrailingItem,
            performSyncIssueAction: { handleFooterAction($0) }
        )
    }

    var body: some View {
        if appDelegate.isLocked, let keychainService = appDelegate.keychainServiceForLock {
            VStack(spacing: 0) {
                searchField
                    .opacity(0.3)
                    .disabled(true)
                Divider()
                    .opacity(0.5)
                LockedView(
                    onUnlockSuccess: { appDelegate.resetAuthTimestamp() },
                    keychainService: keychainService,
                    pendingContext: appDelegate.pendingLockContext,
                    autoUnlockToken: appDelegate.autoUnlockToken,
                    onUnlockPhaseChange: { appDelegate.isUnlockInFlight = $0 }
                )
                .frame(height: 330)
            }
            .frame(minWidth: 480, idealWidth: 580, maxWidth: 620)
            .appGlassBackground(cornerRadius: 16)
        } else {
            unlockedBody
        }
    }

    private var unlockedBody: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
                .opacity(0.5)
            if hasItemContent {
                content
                    .frame(height: 330)
            } else {
                switch contentState.layout {
                case .footerOnly:
                    emptyStateFooter
                case .contentWithFooter:
                    content
                    Divider()
                        .opacity(0.5)
                    emptyStateFooter
                case .contentOnly:
                    content
                }
            }
        }
        .frame(minWidth: 480, idealWidth: 580, maxWidth: 620)
        .appGlassBackground(cornerRadius: 16)
        .task(id: appDelegate.searchFocusRequestID) {
            await focusSearchField()
        }
        .onExitCommand {
            if viewModel.detailItem != nil {
                viewModel.hideDetail()
            } else if !viewModel.searchQuery.isEmpty {
                appDelegate.recordActivity()
                viewModel.searchQuery = ""
            } else {
                onDismiss()
            }
        }
        .onKeyPress(.upArrow) {
            if viewModel.detailItem != nil {
                viewModel.moveRowSelection(by: -1)
            } else {
                viewModel.moveSelection(by: -1)
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if viewModel.detailItem != nil {
                viewModel.moveRowSelection(by: 1)
            } else {
                viewModel.moveSelection(by: 1)
            }
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard viewModel.detailItem == nil else { return .ignored }
            guard !viewModel.items.isEmpty else { return .ignored }
            viewModel.showDetail()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard viewModel.detailItem != nil else { return .ignored }
            viewModel.hideDetail()
            return .handled
        }
        .onKeyPress(.return) {
            viewModel.handleEnter()
            return .handled
        }
        .onKeyPress(keys: ["o"]) { keyPress in
            guard keyPress.modifiers.contains(.command) else { return .ignored }
            guard let item = viewModel.detailItem ?? viewModel.items[safe: viewModel.selectedIndex],
                  item.url != nil else {
                return .ignored
            }
            viewModel.handleAction(.openURL, for: item)
            return .handled
        }
        .onKeyPress(keys: ["r"]) { keyPress in
            guard keyPress.modifiers.contains(.command) else { return .ignored }
            appDelegate.recordActivity()
            NotificationCenter.default.post(name: .refreshRequested, object: nil)
            return .handled
        }
        .onKeyPress(keys: [","]) { keyPress in
            guard keyPress.modifiers.contains(.command) else { return .ignored }
            appDelegate.recordActivity()
            onDismiss()
            NSApp.activate()
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            return .handled
        }
        .onChange(of: viewModel.errorMessage) { _, newValue in
            if let error = newValue {
                AccessibilityNotification.Announcement(error).post()
            }
        }
        .onChange(of: viewModel.syncError) { _, newValue in
            if let syncError = newValue {
                AccessibilityNotification.Announcement(syncError.visibleMessage).post()
            }
        }
        .onChange(of: viewModel.isActionLoading) { oldValue, newValue in
            if !oldValue && newValue {
                AccessibilityNotification.Announcement("Fetching…").post()
            }
        }
    }

    @MainActor
    func handleFooterAction(_ intent: QuickAccessFooterActionIntent) {
        switch intent {
        case .login:
            viewModel.requestPassCLILogin()
        case .updatePAT:
            appDelegate.selectPassCLISettingsTab()
            onDismiss()
            NSApp.activate()
            openSettings()
        case .showSyncIssues, .showSkippedItems:
            appDelegate.showSyncIssueWindow()
        case .itemAction, .showDetail, .copyError, .dismissError:
            return
        }
    }

    @MainActor
    private func focusSearchField() async {
        isSearchFocused = false
        await Task.yield()
        guard !Task.isCancelled, !appDelegate.isLocked else { return }
        isSearchFocused = true
    }

    private var searchField: some View {
        let searchBinding = Binding(
            get: { viewModel.searchQuery },
            set: { newValue in
                appDelegate.recordActivity()
                viewModel.searchQuery = newValue
            }
        )

        return HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search Proton Pass...", text: searchBinding)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isSearchFocused)
            if !viewModel.items.isEmpty {
                Text("\(viewModel.items.count) items")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
    }

}
