import Foundation
import Testing

@Suite("Pass CLI localization readiness")
struct PassCLILocalizationReadinessTests {
    @Test("source option labels use localized strings")
    func sourceOptionLabelsUseLocalizedStrings() throws {
        let source = try sourceFile(named: "Services/Health/PassCLIStatusStore.swift")

        #expect(source.contains("String(localized: \"Bundled latest"))
        #expect(source.contains("String(localized: \"Bundled \\(candidateVersionDescription) (pin this version)"))
        #expect(source.contains("String(localized: \"\\(candidate.path) — version unknown"))
        #expect(!source.contains("label: \"Bundled latest"))
        #expect(!source.contains("?? \" — version unknown\""))
    }

    @Test("recommended version warning uses one localized string")
    func recommendedVersionWarningUsesLocalizedString() throws {
        let source = try sourceFile(named: "Services/Health/PassCLIStatusStore.swift")

        #expect(source.contains("String(\n            localized: \"\"\"\n            Recommended Pass CLI version is"))
        #expect(!source.contains("+ \"If the latest bundled CLI causes problems"))
    }

    @Test("settings source labels and help text use localized strings")
    func settingsSourceTextUsesLocalizedStrings() throws {
        let source = try sourceFile(named: "Views/Settings/PassCLISettingsTab.swift")

        #expect(source.contains("String(localized: \"Custom: \\(path)"))
        #expect(source.contains("String(localized: \"Bundled: pass-cli \\(version)"))
        #expect(source.contains("localized: \"\"\"\n                Included with Quick Access for Pass."))
        #expect(!source.contains("return \"Custom: \\(path)\""))
        #expect(!source.contains("return \"Bundled: pass-cli \\(version)"))
    }

    private func sourceFile(named relativePath: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let projectRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectRoot
            .appendingPathComponent("Quick Access for Pass")
            .appendingPathComponent(relativePath)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
