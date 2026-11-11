import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Sync progress presentation")
struct SyncProgressPresentationTests {

    @Test("vault started shows vault name before item counts are known")
    func vaultStartedText() {
        #expect(SyncProgressPresentation.vaultStarted(vaultName: "Personal").statusText == "Syncing Personal…")
    }

    @Test("decoded items shows count and total")
    func itemCountText() {
        let progress = SyncProgressPresentation.itemsDecoded(
            vaultName: "Personal",
            completedItems: 10,
            totalItems: 400,
            skippedItems: 0
        )
        #expect(progress.statusText == "Syncing Personal 10/400 items")
    }

    @Test("decoded items includes skipped count")
    func skippedCountText() {
        let progress = SyncProgressPresentation.itemsDecoded(
            vaultName: "Work",
            completedItems: 398,
            totalItems: 400,
            skippedItems: 2
        )
        #expect(progress.statusText == "Syncing Work 398/400 items · 2 skipped")
    }

    @Test("completion with skipped items is explicit")
    func completedWithSkippedText() {
        #expect(SyncProgressPresentation.completedWithSkippedItems(3).statusText == "Synced with 3 skipped items")
    }

    @Test("vault name list uses the language of the surrounding status text")
    func restrictedVaultListMatchesTextLanguage() {
        #expect(SyncProgressPresentation.vaultList(["A", "B"], locale: Locale(identifier: "cs")) == "A a\u{00A0}B")
        #expect(SyncProgressPresentation.vaultList(["Osobní %@", "B"], locale: Locale(identifier: "en")) == "Osobní %@ and B")
        // A German system locale must not put "und" inside English text.
        #expect(SyncProgressPresentation.textLocale.language.languageCode?.identifier
            == Bundle.main.preferredLocalizations.first.map { Locale(identifier: $0).language.languageCode?.identifier } ?? "en")
    }


    @Test("skipped items keep the restricted vault note")
    func completedWithSkippedItemsAndRestrictedVaults() {
        let names = SyncProgressPresentation.vaultList(["Shared", "Team"], locale: SyncProgressPresentation.textLocale)
        #expect(SyncProgressPresentation.completedWithSkippedItems(2, restrictedVaultNames: ["Shared", "Team"]).statusText
            == "Synced with 2 skipped items · Passwords hidden by vault policy in \(names)")
        #expect(SyncProgressPresentation.completedWithSkippedItems(2, restrictedVaultNames: []).statusText
            == "Synced with 2 skipped items")
    }

}
