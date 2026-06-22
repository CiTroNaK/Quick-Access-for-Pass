import Testing
import AppKit
@testable import Quick_Access_for_Pass

@Suite("QuickAccessFooterContent")
@MainActor
struct QuickAccessFooterContentTests {

    @Test("detail footer returns passive hints only")
    func detailFooterUsesHints() {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }

        defaults.set(36, forKey: DefaultsKey.showLargeTypeKeyCode)
        defaults.set(Int(NSEvent.ModifierFlags.shift.rawValue), forKey: DefaultsKey.showLargeTypeModifiers)

        let items = QuickAccessFooterContent.detailItems(defaults: defaults)

        #expect(items == [
            .hint(title: "Large Type", shortcut: "⇧Return", collapsesWhenTight: false),
            .hint(title: "Back", shortcut: "←", collapsesWhenTight: false),
        ])
        #expect(QuickAccessFooterContent.largeTypeShortcut(defaults: defaults) == "⇧Return")
        #expect(QuickAccessFooterContent.largeTypeTitle() == "Large Type")
        #expect(QuickAccessFooterContent.backTitle() == "Back")
    }

    @Test("results footer uses button items for primary actions")
    func resultsFooterUsesActionItems() {
        let items = QuickAccessFooterContent.resultsItems(
            actions: [
                .init(intent: .itemAction(.copyPassword), title: "Copy Password", shortcut: "⌘P"),
                .init(intent: .itemAction(.copyUsername), title: "Copy Username", shortcut: "⌘U"),
                .init(intent: .showDetail, title: "More actions", shortcut: "→"),
            ],
            isLoading: false,
            errorContext: nil
        )

        #expect(items == [
            .action(intent: .itemAction(.copyPassword), title: "Copy Password", shortcut: "⌘P"),
            .action(intent: .itemAction(.copyUsername), title: "Copy Username", shortcut: "⌘U"),
            .action(intent: .showDetail, title: "More actions", shortcut: "→"),
        ])
    }

    @Test("results footer keeps More actions as a button intent")
    func resultsFooterKeepsMoreActionsInteractive() {
        let items = QuickAccessFooterContent.resultsItems(
            actions: [
                .init(intent: .itemAction(.copyPassword), title: "Copy Password", shortcut: "⌘P"),
                .init(intent: .showDetail, title: "More actions", shortcut: "→"),
            ],
            isLoading: false,
            errorContext: nil
        )

        #expect(items.last == .action(intent: .showDetail, title: "More actions", shortcut: "→"))
        #expect(items.allSatisfy {
            if case .hint = $0 { return false }
            return true
        })
    }

    @Test("loading and error states stay value-based")
    func loadingAndErrorStates() {
        let loading = QuickAccessFooterContent.resultsItems(
            actions: [],
            isLoading: true,
            errorContext: nil
        )
        #expect(loading == [
            .status(text: "Fetching…", symbol: nil, tone: .secondary, showsProgress: true, collapsesWhenTight: false)
        ])

        let error = QuickAccessFooterContent.resultsItems(
            actions: [],
            isLoading: false,
            errorContext: .init(
                message: "Bad CLI response",
                copyDetails: "Error: Bad CLI response\nCLI path: /opt/homebrew/bin/pass-cli\nLast command: pass show foo"
            )
        )
        #expect(error == [
            .status(
                text: "Bad CLI response",
                symbol: "exclamationmark.triangle.fill",
                tone: .error,
                showsProgress: false,
                collapsesWhenTight: false
            ),
            .hint(title: "Settings", shortcut: "⌘,", collapsesWhenTight: true),
            .action(
                intent: .copyError(
                    details: "Error: Bad CLI response\nCLI path: /opt/homebrew/bin/pass-cli\nLast command: pass show foo"
                ),
                title: "Copy Error",
                shortcut: nil
            ),
            .action(intent: .dismissError, title: "Dismiss", shortcut: nil),
        ])
    }

    @Test("detail vault subtitle uses a localized full string")
    func detailVaultSubtitleUsesLocalizedFullString() {
        #expect(QuickAccessFooterContent.detailVaultSubtitle(vaultName: "Personal") == "In Personal")
    }

    @Test("empty footer localizes full-string shortcut hints")
    func emptyFooterUsesLocalizedFullStrings() {
        let content = QuickAccessFooterContent.emptyStateContent(
            hotkeyLabel: "⇧⌥Space",
            isSyncing: false,
            syncDescription: "5m ago"
        )

        #expect(content.leading == [
            .hint(title: "Show Quick Access", shortcut: "⇧⌥Space", collapsesWhenTight: true),
            .hint(title: "Refresh", shortcut: "⌘R", collapsesWhenTight: true),
            .hint(title: "Settings", shortcut: "⌘,", collapsesWhenTight: true),
        ])
        #expect(content.trailing == .status(text: "Synced 5m ago", symbol: nil, tone: .secondary, showsProgress: false, collapsesWhenTight: false))
    }

    @Test("empty footer shows spinner status while syncing")
    func emptyFooterShowsSyncingStatus() {
        let content = QuickAccessFooterContent.emptyStateContent(
            hotkeyLabel: "⇧⌥Space",
            isSyncing: true,
            syncDescription: "5m ago"
        )

        #expect(content.leading == [
            .hint(title: "Show Quick Access", shortcut: "⇧⌥Space", collapsesWhenTight: true),
            .hint(title: "Refresh", shortcut: "⌘R", collapsesWhenTight: true),
            .hint(title: "Settings", shortcut: "⌘,", collapsesWhenTight: true),
        ])
        #expect(content.trailing == .status(text: "Syncing…", symbol: nil, tone: .secondary, showsProgress: true, collapsesWhenTight: false))
    }

    @Test("empty footer places sync status in trailing slot")
    func emptyFooterPlacesSyncStatusInTrailingSlot() {
        let content = QuickAccessFooterContent.emptyStateContent(
            hotkeyLabel: "⌥Space",
            isSyncing: false,
            syncDescription: "just now"
        )

        #expect(content.leading == [
            .hint(title: "Show Quick Access", shortcut: "⌥Space", collapsesWhenTight: true),
            .hint(title: "Refresh", shortcut: "⌘R", collapsesWhenTight: true),
            .hint(title: "Settings", shortcut: "⌘,", collapsesWhenTight: true),
        ])
        #expect(content.trailing == .status(
            text: "Synced just now",
            symbol: nil,
            tone: .secondary,
            showsProgress: false,
            collapsesWhenTight: false
        ))
    }

    @Test("empty footer uses rich sync progress text while syncing")
    func emptyFooterUsesRichSyncProgressText() {
        let content = QuickAccessFooterContent.emptyStateContent(
            hotkeyLabel: "⌥Space",
            isSyncing: true,
            syncStatusText: "Syncing Personal 10/400 items",
            syncDescription: "5m ago"
        )

        #expect(content.trailing == .status(
            text: "Syncing Personal 10/400 items",
            symbol: nil,
            tone: .secondary,
            showsProgress: true,
            collapsesWhenTight: false
        ))
    }

    @Test("empty footer shows completed sync progress even after loading finishes")
    func emptyFooterShowsCompletedSyncProgress() {
        let content = QuickAccessFooterContent.emptyStateContent(
            hotkeyLabel: "⌥Space",
            isSyncing: false,
            syncProgress: .completedWithSkippedItems(3),
            syncDescription: "just now"
        )

        #expect(content.trailing == .status(
            text: "Synced with 3 skipped items",
            symbol: nil,
            tone: .secondary,
            showsProgress: false,
            collapsesWhenTight: false
        ))
    }

    @Test("sync issue trailing actions are visually prominent")
    func syncIssueTrailingActionsAreVisuallyProminent() {
        let loginItem = QuickAccessFooterContent.syncIssueTrailingItem(
            syncError: .loginRequired(),
            hasSkippedItems: false
        )
        let syncErrorsItem = QuickAccessFooterContent.syncIssueTrailingItem(
            syncError: .genericFailure(diagnosticReport: "diagnostic"),
            hasSkippedItems: false
        )
        let updatePATItem = QuickAccessFooterContent.syncIssueTrailingItem(
            syncError: .invalidPAT(userFacingMessage: "Personal access token is invalid, expired, or deleted."),
            hasSkippedItems: false
        )
        let normalItem = QuickAccessFooterItem.action(
            intent: .itemAction(.copyPassword),
            title: "Copy Password",
            shortcut: "⌘P"
        )

        #expect(loginItem?.isProminentFooterAction == true)
        #expect(syncErrorsItem?.isProminentFooterAction == true)
        #expect(updatePATItem?.isProminentFooterAction == true)
        #expect(normalItem.isProminentFooterAction == false)
    }

    @Test("sync issue trailing item shows Login for login-required errors")
    func syncIssueTrailingItemShowsLoginForLoginRequiredErrors() {
        let item = QuickAccessFooterContent.syncIssueTrailingItem(
            syncError: .loginRequired(),
            hasSkippedItems: false
        )

        #expect(item == .action(intent: .login, title: "Login", shortcut: nil))
    }

    @Test("sync issue trailing item shows Update PAT for invalid personal access token")
    func syncIssueTrailingItemShowsUpdatePATForInvalidPersonalAccessToken() {
        let item = QuickAccessFooterContent.syncIssueTrailingItem(
            syncError: .invalidPAT(userFacingMessage: "Personal access token is invalid, expired, or deleted."),
            hasSkippedItems: true
        )

        #expect(item == .action(intent: .updatePAT, title: "Update PAT", shortcut: nil))
    }

    @Test("sync issue trailing item shows sync errors for generic failures")
    func syncIssueTrailingItemShowsSyncErrorsForGenericFailures() {
        let item = QuickAccessFooterContent.syncIssueTrailingItem(
            syncError: .genericFailure(diagnosticReport: "diagnostic"),
            hasSkippedItems: false
        )

        #expect(item == .action(intent: .showSyncIssues, title: "Show sync errors", shortcut: nil))
    }

    @Test("sync issue trailing item shows sync errors for skipped items")
    func syncIssueTrailingItemShowsSyncErrorsForSkippedItems() {
        let item = QuickAccessFooterContent.syncIssueTrailingItem(
            syncError: nil,
            hasSkippedItems: true
        )

        #expect(item == .action(intent: .showSyncIssues, title: "Show sync errors", shortcut: nil))
    }

    @Test("empty footer keeps left shortcuts while Login appears on right")
    func emptyFooterKeepsLeftShortcutsWhileLoginAppearsOnRight() {
        let content = QuickAccessFooterContent.emptyStateContent(
            hotkeyLabel: "⇧⌥Space",
            isSyncing: false,
            syncIssueTrailingItem: .action(intent: .login, title: "Login", shortcut: nil),
            syncDescription: "5m ago"
        )

        #expect(content.leading == [
            .hint(title: "Show Quick Access", shortcut: "⇧⌥Space", collapsesWhenTight: true),
            .hint(title: "Refresh", shortcut: "⌘R", collapsesWhenTight: true),
            .hint(title: "Settings", shortcut: "⌘,", collapsesWhenTight: true),
        ])
        #expect(content.trailing == .action(intent: .login, title: "Login", shortcut: nil))
    }

    @Test("sync issue action overrides normal empty-state sync status on the right")
    func syncIssueActionOverridesNormalEmptyStateSyncStatusOnTheRight() {
        let content = QuickAccessFooterContent.emptyStateContent(
            hotkeyLabel: "⇧⌥Space",
            isSyncing: false,
            syncIssueTrailingItem: .action(intent: .showSyncIssues, title: "Show sync errors", shortcut: nil),
            syncDescription: "5m ago"
        )

        #expect(content.leading == [
            .hint(title: "Show Quick Access", shortcut: "⇧⌥Space", collapsesWhenTight: true),
            .hint(title: "Refresh", shortcut: "⌘R", collapsesWhenTight: true),
            .hint(title: "Settings", shortcut: "⌘,", collapsesWhenTight: true),
        ])
        #expect(content.trailing == .action(intent: .showSyncIssues, title: "Show sync errors", shortcut: nil))
    }

    @Test("skipped items do not add a legacy left-side footer action")
    func skippedItemsDoNotAddLegacyLeftSideFooterAction() {
        let content = QuickAccessFooterContent.emptyStateContent(
            hotkeyLabel: "⇧⌥Space",
            isSyncing: false,
            hasSkippedItems: true,
            syncDescription: "5m ago"
        )

        #expect(content.leading == [
            .hint(title: "Show Quick Access", shortcut: "⇧⌥Space", collapsesWhenTight: true),
            .hint(title: "Refresh", shortcut: "⌘R", collapsesWhenTight: true),
            .hint(title: "Settings", shortcut: "⌘,", collapsesWhenTight: true),
        ])
    }

    @Test("sync issue trailing actions carry action-specific warning presentation")
    func syncIssueTrailingActionsCarryActionSpecificWarningPresentation() throws {
        let loginItem = try #require(QuickAccessFooterContent.syncIssueTrailingItem(
            syncError: .loginRequired(),
            hasSkippedItems: false
        ))
        let updatePATItem = try #require(QuickAccessFooterContent.syncIssueTrailingItem(
            syncError: .invalidPAT(userFacingMessage: "Personal access token is invalid, expired, or deleted."),
            hasSkippedItems: false
        ))
        let syncErrorsItem = try #require(QuickAccessFooterContent.syncIssueTrailingItem(
            syncError: .genericFailure(diagnosticReport: "diagnostic"),
            hasSkippedItems: false
        ))
        let skippedItemsItem = try #require(QuickAccessFooterContent.syncIssueTrailingItem(
            syncError: nil,
            hasSkippedItems: true
        ))

        #expect(loginItem.footerActionPresentation == .prominent(symbolName: "lock.open.fill", tone: .warning))
        #expect(updatePATItem.footerActionPresentation == .prominent(symbolName: "key.fill", tone: .warning))
        #expect(syncErrorsItem.footerActionPresentation == .prominent(symbolName: "exclamationmark.triangle.fill", tone: .error))
        #expect(skippedItemsItem.footerActionPresentation == .prominent(symbolName: "exclamationmark.triangle.fill", tone: .error))
    }

    @Test("ordinary footer actions use plain fallback presentation")
    func ordinaryFooterActionsUsePlainFallbackPresentation() {
        let item = QuickAccessFooterItem.action(
            intent: .itemAction(.copyPassword),
            title: "Copy Password",
            shortcut: "⌘P"
        )

        #expect(item.footerActionPresentation == .plain)
        #expect(item.isProminentFooterAction == false)
    }

    @Test("prominent footer action metrics stay compact")
    func prominentFooterActionMetricsStayCompact() {
        #expect(QuickAccessFooter.prominentActionHeight == 24)
        #expect(QuickAccessFooter.prominentActionHorizontalPadding == 10)
        #expect(QuickAccessFooter.prominentActionVerticalPadding == 6)
    }

    @Test("footer reduces vertical padding around prominent trailing actions")
    func footerReducesVerticalPaddingAroundProminentTrailingActions() {
        let prominentItem = QuickAccessFooterItem.action(intent: .updatePAT, title: "Update PAT", shortcut: nil)
        let statusItem = QuickAccessFooterItem.status(
            text: "Logging in with saved PAT…",
            symbol: nil,
            tone: .secondary,
            showsProgress: true,
            collapsesWhenTight: false
        )

        #expect(QuickAccessFooter.verticalPadding(for: prominentItem) == 6)
        #expect(QuickAccessFooter.verticalPadding(for: statusItem) == 10)
        #expect(QuickAccessFooter.verticalPadding(for: nil) == 10)
    }
}
