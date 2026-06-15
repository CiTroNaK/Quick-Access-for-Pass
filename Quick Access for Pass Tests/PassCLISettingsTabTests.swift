import Testing
import Foundation

@Suite("Pass CLI settings copy")
struct PassCLISettingsTabTests {
    @Test("settings source copy includes custom no fallback guidance")
    func sourceContainsCustomNoFallbackGuidance() throws {
        let source = try settingsSource()

        #expect(source.contains("Clear this field to use auto-detection and bundled fallback."))
        #expect(source.contains("No fallback is attempted while a custom path is set."))
    }

    @Test("settings source copy explains bundled app update cadence")
    func sourceContainsBundledUpdateCadence() throws {
        let source = try settingsSource()

        #expect(source.contains("Included with Quick Access for Pass. Updates with the app."))
    }

    @Test("settings source labels all CLI source modes")
    func sourceLabelsAllCLISourceModes() throws {
        let source = try settingsSource()

        #expect(source.contains("Custom:"))
        #expect(source.contains("System:"))
        #expect(source.contains("Bundled:"))
    }

    private func settingsSource() throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let projectRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectRoot
            .appendingPathComponent("Quick Access for Pass")
            .appendingPathComponent("Views/Settings/PassCLISettingsTab.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
