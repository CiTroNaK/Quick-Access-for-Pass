import Foundation
import Testing

@Suite("Settings menu localization readiness")
struct SettingsMenuLocalizationReadinessTests {
    @Test func settingsCommandHasCzechTranslationAndUnicodeEllipsis() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Quick Access for Pass/Resources/Localizable.xcstrings")
        let catalog = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(catalog["sourceLanguage"] as? String == "en")
        let strings = try #require(catalog["strings"] as? [String: Any])
        let command = try #require(strings["Settings…"] as? [String: Any])
        let localizations = try #require(command["localizations"] as? [String: Any])
        let czech = try #require(localizations["cs"] as? [String: Any])
        let unit = try #require(czech["stringUnit"] as? [String: Any])
        #expect(unit["state"] as? String == "translated")
        #expect(unit["value"] as? String == "Nastavení…")
        #expect(strings["Settings..."] == nil)
    }
}
