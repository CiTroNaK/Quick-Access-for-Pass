import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Quick_Access_for_Pass

@Suite("AutoFill localization")
@MainActor
struct AutoFillLocalizationTests {
    @Test(arguments: [
        ("Recently used", "Nedávno použito"),
        ("Exact site match", "Přesná shoda webu"),
        ("autoFillResolvingMessage", "Načítání přihlašovacích údajů…"),
        ("autoFillResolvingAccessibility", "Načítání přihlašovacích údajů"),
        ("autoFillSearchCredentials", "Hledat přihlašovací údaje"),
        ("offlineLastRefreshedStatus", "%@, poslední aktualizace %@"),
        ("offlineVaultLastRefreshedStatus", "Vybráno: %lld, použitelných: %lld, poslední aktualizace %@"),
        ("sshDecisionKey", "Klíč: %@"),
        ("sshUnknownKey", "Klíč %@...")
    ])
    func czechPresentationMessages(key: String, expected: String) throws {
        let bundle = try languageBundle("cs")
        #expect(bundle.localizedString(forKey: key, value: "MISSING", table: "Localizable") == expected)
    }

    @Test(arguments: [
        (0, "0 credentials", "0 přihlašovacích údajů"),
        (1, "1 credential", "1 přihlašovací údaj"),
        (2, "2 credentials", "2 přihlašovací údaje"),
        (5, "5 credentials", "5 přihlašovacích údajů")
    ])
    func credentialCountPluralForms(count: Int, english: String, czech: String) throws {
        for (language, expected) in [("en", english), ("cs", czech)] {
            let actual = AutoFillLocalizedText.resultCount(count, locale: Locale(identifier: language))
            #expect(actual == expected)
        }
    }

    @Test(arguments: [
        (0, "0 matching credentials", "0 odpovídajících přihlašovacích údajů"),
        (1, "1 matching credential", "1 odpovídající přihlašovací údaj"),
        (2, "2 matching credentials", "2 odpovídající přihlašovací údaje"),
        (5, "5 matching credentials", "5 odpovídajících přihlašovacích údajů")
    ])
    func matchingCountPluralForms(count: Int, english: String, czech: String) {
        #expect(AutoFillLocalizedText.matchingResultCount(count, locale: Locale(identifier: "en")) == english)
        #expect(AutoFillLocalizedText.matchingResultCount(count, locale: Locale(identifier: "cs")) == czech)
    }

    @Test func candidateLabelsAndAnnouncementsPreserveAccountText() {
        let candidate = AutoFillCandidate(
            descriptorID: UUID(), title: "Proton, účet — 東京", username: "a+b@example.com",
            kind: .oneTimeCode, matchTier: 0, isRecentlyUsed: true
        )
        let czech = Locale(identifier: "cs")
        #expect(AutoFillLocalizedText.candidateAccessibilityLabel(candidate, exactMatch: true, locale: czech)
            == "Proton, účet — 東京, a+b@example.com, Nedávno použito, Přesná shoda webu")
        #expect(AutoFillLocalizedText.candidateAccessibilityLabel(candidate, exactMatch: false, locale: czech)
            == "Proton, účet — 東京, a+b@example.com, Nedávno použito")
        #expect(AutoFillLocalizedText.selectedAnnouncement(candidate, locale: czech)
            == "Vybráno Proton, účet — 東京, a+b@example.com")
        #expect(AutoFillLocalizedText.string(.autoFillResolvingMessage, locale: czech)
            == "Načítání přihlašovacích údajů…")
        #expect(AutoFillLocalizedText.string(.autoFillResolvingAccessibility, locale: czech)
            == "Načítání přihlašovacích údajů")
        #expect(AutoFillLocalizedText.string("Cancel", locale: czech) == "Zrušit")
    }

    @Test func nativeSearchFieldUsesAndUpdatesViewLocale() throws {
        let host = NSHostingView(rootView: SearchFixture().environment(\.locale, Locale(identifier: "cs")))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 40)
        host.layoutSubtreeIfNeeded()
        let field = try #require(searchField(in: host))
        #expect(field.placeholderString == "Hledat přihlašovací údaje")
        #expect(field.accessibilityLabel() == "Hledat přihlašovací údaje")

        host.rootView = SearchFixture().environment(\.locale, Locale(identifier: "en"))
        host.layoutSubtreeIfNeeded()
        let updated = try #require(searchField(in: host))
        #expect(updated === field)
        #expect(updated.placeholderString == "Search credentials")
        #expect(updated.accessibilityLabel() == "Search credentials")
    }

    @Test func allTranslatableCatalogEntriesHaveCzech() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Quick Access for Pass/Resources/Localizable.xcstrings"))
        let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: [String: Any]])
        for (key, entry) in strings where entry["shouldTranslate"] as? Bool != false {
            let localizations = entry["localizations"] as? [String: Any]
            #expect(localizations?["cs"] != nil, "Missing Czech translation: \(key)")
        }
    }

    private func languageBundle(_ language: String) throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    private func searchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        return view.subviews.lazy.compactMap { searchField(in: $0) }.first
    }

    private struct SearchFixture: View {
        @FocusState private var target: AutoFillCandidatePickerFocusTarget?

        var body: some View {
            AutoFillPickerSearchField(
                text: .constant(""), focusTarget: $target,
                onMoveSelectionUp: {}, onMoveSelectionDown: {}, onFill: {}, onCancel: {}, onTab: {}
            )
        }
    }
}
