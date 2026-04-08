import AppKit
import Foundation

nonisolated enum QuickAccessFooterActionIntent: Equatable, Sendable {
    case itemAction(ItemAction)
    case showDetail
    case copyError(details: String)
    case dismissError
}

nonisolated enum QuickAccessFooterTone: Equatable, Sendable {
    case secondary
    case error
}

nonisolated enum QuickAccessFooterItem: Equatable, Identifiable, Sendable {
    case action(intent: QuickAccessFooterActionIntent, title: String, shortcut: String?)
    case hint(title: String, shortcut: String?, collapsesWhenTight: Bool)
    case status(text: String, symbol: String?, tone: QuickAccessFooterTone, showsProgress: Bool, collapsesWhenTight: Bool)

    var id: String {
        switch self {
        case .action(let intent, let title, let shortcut):
            return "action:\(String(describing: intent)):\(title):\(shortcut ?? "")"
        case .hint(let title, let shortcut, _):
            return "hint:\(title):\(shortcut ?? "")"
        case .status(let text, let symbol, let tone, let showsProgress, _):
            return "status:\(text):\(symbol ?? ""):\(String(describing: tone)):\(showsProgress)"
        }
    }

    var collapsesWhenTight: Bool {
        switch self {
        case .action:
            false
        case .hint(_, _, let collapsesWhenTight), .status(_, _, _, _, let collapsesWhenTight):
            collapsesWhenTight
        }
    }
}

nonisolated struct QuickAccessFooterActionDescriptor: Equatable, Sendable {
    let intent: QuickAccessFooterActionIntent
    let title: String
    let shortcut: String?
}

nonisolated struct QuickAccessFooterErrorContext: Equatable, Sendable {
    let message: String
    let copyDetails: String
}

nonisolated struct QuickAccessFooterContentModel: Equatable, Sendable {
    let leading: [QuickAccessFooterItem]
    let trailing: QuickAccessFooterItem?
}

enum QuickAccessFooterContent {
    static func emptyStateContent(
        hotkeyLabel: String,
        isSyncing: Bool,
        syncDescription: String?
    ) -> QuickAccessFooterContentModel {
        let leading: [QuickAccessFooterItem] = [
            .hint(title: showQuickAccessTitle(), shortcut: hotkeyLabel, collapsesWhenTight: true),
            .hint(title: refreshTitle(), shortcut: "⌘R", collapsesWhenTight: true),
            .hint(title: settingsTitle(), shortcut: "⌘,", collapsesWhenTight: true),
        ]

        let trailing: QuickAccessFooterItem?
        if isSyncing {
            trailing = .status(
                text: String(
                    localized: "Syncing…",
                    comment: "Footer status while the app is syncing Proton Pass metadata."
                ),
                symbol: nil,
                tone: .secondary,
                showsProgress: true,
                collapsesWhenTight: false
            )
        } else if let syncDescription {
            trailing = .status(
                text: String(
                    localized: "Synced \(syncDescription)",
                    comment: "Footer status showing relative time since the last successful sync."
                ),
                symbol: nil,
                tone: .secondary,
                showsProgress: false,
                collapsesWhenTight: false
            )
        } else {
            trailing = nil
        }

        return QuickAccessFooterContentModel(leading: leading, trailing: trailing)
    }

    static func emptyStateItems(
        hotkeyLabel: String,
        isSyncing: Bool,
        syncDescription: String?
    ) -> [QuickAccessFooterItem] {
        let content = emptyStateContent(
            hotkeyLabel: hotkeyLabel,
            isSyncing: isSyncing,
            syncDescription: syncDescription
        )
        return content.leading + (content.trailing.map { [$0] } ?? [])
    }

    static func resultsItems(
        actions: [QuickAccessFooterActionDescriptor],
        isLoading: Bool,
        errorContext: QuickAccessFooterErrorContext?
    ) -> [QuickAccessFooterItem] {
        if isLoading {
            return [
                .status(
                    text: String(
                        localized: "Fetching…",
                        comment: "Footer status while loading the selected item action."
                    ),
                    symbol: nil,
                    tone: .secondary,
                    showsProgress: true,
                    collapsesWhenTight: false
                )
            ]
        }

        if let errorContext {
            return [
                .status(
                    text: errorContext.message,
                    symbol: "exclamationmark.triangle.fill",
                    tone: .error,
                    showsProgress: false,
                    collapsesWhenTight: false
                ),
                .action(intent: .copyError(details: errorContext.copyDetails), title: String(localized: "Copy Error"), shortcut: nil),
                .action(intent: .dismissError, title: String(localized: "Dismiss"), shortcut: nil),
            ]
        }

        return actions.map { descriptor in
            .action(intent: descriptor.intent, title: descriptor.title, shortcut: descriptor.shortcut)
        }
    }

    @MainActor
    static func detailItems(defaults: UserDefaults = .standard) -> [QuickAccessFooterItem] {
        [
            .hint(title: largeTypeTitle(), shortcut: largeTypeShortcut(defaults: defaults), collapsesWhenTight: false),
            .hint(title: backTitle(), shortcut: "←", collapsesWhenTight: false),
        ]
    }

    static func showQuickAccessTitle() -> String {
        String(localized: "Show Quick Access", comment: "Footer hint label for opening Quick Access.")
    }

    static func refreshTitle() -> String {
        String(localized: "Refresh", comment: "Footer hint label for refreshing items.")
    }

    static func settingsTitle() -> String {
        String(localized: "Settings", comment: "Footer hint label for opening Settings.")
    }

    @MainActor
    static func largeTypeShortcut(defaults: UserDefaults = .standard) -> String {
        let keyCode = defaults.object(forKey: DefaultsKey.showLargeTypeKeyCode) as? Int ?? 36
        let modifiers = defaults.object(forKey: DefaultsKey.showLargeTypeModifiers) as? Int
            ?? Int(NSEvent.ModifierFlags.shift.rawValue)
        return ShortcutFormatting.label(keyCode: keyCode, modifiers: modifiers)
    }

    static func largeTypeTitle() -> String {
        String(localized: "Large Type", comment: "Footer hint label for showing the selected value in Large Type.")
    }

    static func backTitle() -> String {
        String(localized: "Back", comment: "Footer hint label for returning from item detail back to the results list.")
    }

    static func detailVaultSubtitle(vaultName: String) -> String {
        String(localized: "In \(vaultName)", comment: "Item detail subtitle showing which vault contains the selected item.")
    }
}
