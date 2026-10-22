import Foundation
import Testing

@Suite("Compiled localization bundles")
struct LocalizationBundleTests {
    @Test func hostContainsCzechTranslations() throws {
        try expectCzechCancel(in: Bundle.main)
    }

    @Test func extensionContainsItsOwnCzechTranslations() throws {
        let plugins = try #require(Bundle.main.builtInPlugInsURL)
        let extensionBundle = try #require(Bundle(url: plugins.appendingPathComponent("Quick Access AutoFill.appex")))
        try expectCzechCancel(in: extensionBundle)
    }

    private func expectCzechCancel(in bundle: Bundle) throws {
        #expect(bundle.localizations.contains("en"))
        let path = try #require(bundle.path(forResource: "cs", ofType: "lproj"))
        let czech = try #require(Bundle(path: path))
        #expect(czech.localizedString(forKey: "Cancel", value: "MISSING", table: "Localizable") == "Zrušit")
    }
}
