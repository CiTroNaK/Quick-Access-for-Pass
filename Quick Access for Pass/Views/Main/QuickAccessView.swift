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
    @FocusState private var isSearchFocused: Bool

    private var hotkeyLabel: String {
        let code = UserDefaults.standard.integer(forKey: DefaultsKey.hotkeyCode)
        let mods = UserDefaults.standard.integer(forKey: DefaultsKey.hotkeyModifiers)
        if code > 0 && mods > 0 {
            return ShortcutFormatting.label(keyCode: code, modifiers: mods)
        }
        return "⇧⌥Space"
    }

    private var hasItemContent: Bool {
        viewModel.detailItem != nil || !viewModel.items.isEmpty
    }

    private var hasEmptyState: Bool {
        viewModel.errorMessage != nil
        || (!viewModel.searchQuery.isEmpty && viewModel.items.isEmpty)
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
            } else if hasEmptyState {
                content
            } else {
                QuickAccessShortcutHints(
                    hotkeyLabel: hotkeyLabel,
                    isLoading: viewModel.isLoading,
                    hasItems: !viewModel.items.isEmpty,
                    searchQuery: viewModel.searchQuery
                )
            }
        }
        .frame(minWidth: 480, idealWidth: 580, maxWidth: 620)
        .appGlassBackground(cornerRadius: 16)
        .onAppear { isSearchFocused = true }
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
        .onChange(of: viewModel.isActionLoading) { oldValue, newValue in
            if !oldValue && newValue {
                AccessibilityNotification.Announcement("Fetching…").post()
            }
        }
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

    @ViewBuilder
    private var content: some View {
        if let detailItem = viewModel.detailItem {
            VStack(spacing: 0) {
                ItemDetailView(
                    item: detailItem,
                    viewModel: viewModel,
                    onBack: { viewModel.hideDetail() }
                )
                .frame(maxHeight: .infinity)

                if let error = viewModel.errorMessage {
                    Divider()
                        .opacity(0.5)
                    detailErrorBar(error)
                }
            }
        } else if !viewModel.items.isEmpty {
            VStack(spacing: 0) {
                QuickAccessResultsList(
                    items: viewModel.items,
                    selectedIndex: viewModel.selectedIndex,
                    vaultName: viewModel.vaultName(for:),
                    showDetailAtIndex: { index in
                        viewModel.selectedIndex = index
                        viewModel.showDetail()
                    }
                )
                Divider()
                    .opacity(0.5)
                QuickAccessActionBar(viewModel: viewModel)
            }
        } else if let error = viewModel.errorMessage {
            QuickAccessEmptyStateView(message: error, secondaryMessage: nil, systemImage: nil)
        } else if !viewModel.searchQuery.isEmpty {
            QuickAccessEmptyStateView(
                message: "No items found",
                secondaryMessage: "Try a different search or press ⌘R to refresh",
                systemImage: "magnifyingglass"
            )
        }
    }

    private func detailErrorBar(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
            Spacer()
            Button("Dismiss") { viewModel.errorMessage = nil }
                .font(.caption)
                .appClearGlassButtonStyle()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
