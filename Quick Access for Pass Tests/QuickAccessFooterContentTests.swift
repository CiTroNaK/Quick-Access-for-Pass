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
            .status(text: "Bad CLI response", symbol: "exclamationmark.triangle.fill", tone: .error, showsProgress: false, collapsesWhenTight: false),
            .action(intent: .copyError(details: "Error: Bad CLI response\nCLI path: /opt/homebrew/bin/pass-cli\nLast command: pass show foo"), title: "Copy Error", shortcut: nil),
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
}
