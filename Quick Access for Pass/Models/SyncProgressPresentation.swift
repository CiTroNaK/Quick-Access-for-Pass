import Foundation

nonisolated struct SyncProgressPresentation: Equatable, Sendable {
    let statusText: String
    let showsProgress: Bool

    static func loggingInWithSavedPAT() -> SyncProgressPresentation {
        SyncProgressPresentation(
            statusText: String(
                localized: "Logging in with saved PAT…",
                comment: "Footer status while recreating a Pass CLI session with a saved personal access token."
            ),
            showsProgress: true
        )
    }

    static func vaultStarted(vaultName: String) -> SyncProgressPresentation {
        SyncProgressPresentation(
            statusText: String(
                localized: "Syncing \(vaultName)…",
                comment: "Sync status shown while fetching a specific Proton Pass vault."
            ),
            showsProgress: true
        )
    }

    static func itemsDecoded(
        vaultName: String,
        completedItems: Int,
        totalItems: Int,
        skippedItems: Int
    ) -> SyncProgressPresentation {
        let base = String(
            localized: "Syncing \(vaultName) \(completedItems)/\(totalItems) items",
            comment: "Sync status showing decoded item progress for a Proton Pass vault."
        )
        let text = skippedItems > 0
            ? base + String(localized: " · \(skippedItems) skipped", comment: "Suffix for skipped sync items.")
            : base
        return SyncProgressPresentation(statusText: text, showsProgress: true)
    }

    static func completedWithRestrictedVaults(_ vaultNames: [String]) -> SyncProgressPresentation {
        let names = vaultNames.formatted(.list(type: .and))
        return SyncProgressPresentation(
            statusText: String(
                localized: "Synced · Passwords hidden by vault policy in \(names)",
                comment: "Sync status after a sync where shared vaults hide sensitive content from Pass CLI. Placeholder is a list of unchanged vault names."
            ),
            showsProgress: false
        )
    }

    static func completedWithSkippedItems(_ count: Int) -> SyncProgressPresentation {
        SyncProgressPresentation(
            statusText: String(
                localized: "Synced with \(count) skipped items",
                comment: "Sync status after a successful sync that skipped malformed items."
            ),
            showsProgress: false
        )
    }
}
