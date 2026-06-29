import Testing
@testable import Quick_Access_for_Pass

@Suite("Pass CLI selection preference")
struct PassCLISelectionPreferenceTests {
    @Test("parses persisted raw values")
    func parsesRawValues() {
        #expect(PassCLISelectionPreference(rawValue: "auto") == .auto)
        #expect(PassCLISelectionPreference(rawValue: "custom") == .custom)
        #expect(PassCLISelectionPreference(rawValue: "installed:/opt/homebrew/bin/pass-cli") == .installed(path: "/opt/homebrew/bin/pass-cli"))
        #expect(PassCLISelectionPreference(rawValue: "bundled:latest") == .bundled(.latest))
        #expect(PassCLISelectionPreference(rawValue: "bundled:2.1.4") == .bundled(.version("2.1.4")))
    }

    @Test("formats persisted raw values")
    func formatsRawValues() {
        #expect(PassCLISelectionPreference.auto.rawValue == "auto")
        #expect(PassCLISelectionPreference.custom.rawValue == "custom")
        #expect(PassCLISelectionPreference.installed(path: "/opt/homebrew/bin/pass-cli").rawValue == "installed:/opt/homebrew/bin/pass-cli")
        #expect(PassCLISelectionPreference.bundled(.latest).rawValue == "bundled:latest")
        #expect(PassCLISelectionPreference.bundled(.version("2.1.4")).rawValue == "bundled:2.1.4")
    }

    @Test("migrates missing selection from existing cliPath")
    func migratesFromExistingCLIPath() {
        #expect(PassCLISelectionPreference.resolved(rawValue: nil, legacyCustomPath: "") == .auto)
        #expect(PassCLISelectionPreference.resolved(rawValue: nil, legacyCustomPath: nil) == .auto)
        #expect(PassCLISelectionPreference.resolved(rawValue: nil, legacyCustomPath: "/custom/pass-cli") == .custom)
    }

    @Test("invalid raw values fall back to auto")
    func invalidRawValuesFallbackToAuto() {
        #expect(PassCLISelectionPreference.resolved(rawValue: "bundled:", legacyCustomPath: "/custom/pass-cli") == .auto)
        #expect(PassCLISelectionPreference.resolved(rawValue: "installed:", legacyCustomPath: nil) == .auto)
        #expect(PassCLISelectionPreference.resolved(rawValue: "wat", legacyCustomPath: nil) == .auto)
    }
}
