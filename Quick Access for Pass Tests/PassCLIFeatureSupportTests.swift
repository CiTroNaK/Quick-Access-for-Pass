import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Pass CLI feature support")
struct PassCLIFeatureSupportTests {
    private static let v250 = PassCLIVersion(major: 2, minor: 5, patch: 0)

    @Test(arguments: [
        ("2.1.4", [PassCLIFeatureStatus.unsupported(minimumVersion: v250), .supported]),
        ("2.4.2", [.unsupported(minimumVersion: v250), .supported]),
        // Untested older releases can reach fast offline sync through a tested release, not only 2.5.0+.
        ("2.4.0", [.unsupported(minimumVersion: v250), .unverifiedRelease(minimumVersion: v250)]),
        ("2.5.0", [.untested, .untested]),
        ("2.5.1", [.supported, .supported]),
        ("2.7.0", [.supported, .supported, .supported]),
        ("2.8.0", [.untested, .untested, .untested])
    ])
    func statusFollowsVersionRules(raw: String, expected: [PassCLIFeatureStatus]) {
        let rows = PassCLICapabilities(rawVersionString: "Proton Pass CLI \(raw) (abc1234)").featureSupport
        #expect(rows.map(\.status) == expected)
        let features: [PassCLIFeature] = [.folders, .fastOfflineSync, .vaultPasswordPolicy]
        #expect(rows.map(\.feature) == Array(features.prefix(expected.count)))
    }

    @Test(arguments: [nil, "", "not a version"] as [String?])
    func unknownVersionHasNoRows(raw: String?) {
        #expect(PassCLICapabilities(rawVersionString: raw).featureSupport.isEmpty)
    }

    @Test("summary agrees with the gates that enable each feature")
    func summaryMatchesFeatureGates() {
        for raw in ["2.0.3", "2.2.2", "2.4.2", "2.5.0", "2.5.1", "2.6.0", "2.7.0", "3.0.0"] {
            let capabilities = PassCLICapabilities(rawVersionString: raw)
            let status = Dictionary(uniqueKeysWithValues: capabilities.featureSupport.map { ($0.feature, $0.status) })
            let available: (PassCLIFeature) -> Bool = { status[$0]?.isAvailable ?? false }
            #expect(available(.folders) == capabilities.supportsFolders)
            #expect(available(.fastOfflineSync) == capabilities.snapshotContentProvenance.isCompleteJSON)
        }
    }

    @Test(arguments: ["en", "cs"])
    func pillTextUsesTheViewLocale(language: String) {
        let locale = Locale(identifier: language)
        let czech = language == "cs"
        #expect(PassCLIFeatureSupportView.statusText(for: .supported, locale: locale) == (czech ? "Podporováno" : "Supported"))
        #expect(PassCLIFeatureSupportView.statusText(for: .untested, locale: locale) == (czech ? "Neotestováno" : "Untested"))
        #expect(PassCLIFeatureSupportView.statusText(for: .unsupported(minimumVersion: nil), locale: locale)
            == (czech ? "Nepodporováno" : "Unsupported"))
        #expect(PassCLIFeatureSupportView.title(for: .fastOfflineSync, locale: locale)
            == (czech ? "Rychlá offline synchronizace" : "Fast offline sync"))
        #expect(PassCLIFeatureSupportView.detail(for: .unsupported(minimumVersion: Self.v250), locale: locale)
            == (czech ? "Vyžaduje 2.5.0 nebo novější" : "Needs 2.5.0 or newer"))
        #expect(PassCLIFeatureSupportView.detail(for: .unsupported(minimumVersion: nil), locale: locale)
            == (czech ? "Pro tuto verzi vypnuto" : "Disabled for this version"))
        #expect(PassCLIFeatureSupportView.detail(for: .untested, locale: locale) == nil)
        #expect(PassCLIFeatureSupportView.statusText(for: .unverifiedRelease(minimumVersion: Self.v250), locale: locale)
            == (czech ? "Nepodporováno" : "Unsupported"))
        #expect(PassCLIFeatureSupportView.detail(for: .unverifiedRelease(minimumVersion: Self.v250), locale: locale)
            == (czech ? "Tato verze není ověřena · Použijte ověřené vydání nebo 2.5.0+"
                      : "Not verified for this version · Use a tested release or 2.5.0+"))
    }
}
