import Foundation
import Testing

@Suite("Pass CLI settings layout")
struct PassCLISettingsTabLayoutTests {
    @Test("personal access token captions opt into multiline layout")
    func personalAccessTokenCaptionsUseMultilineLayout() throws {
        let source = try passCLISettingsTabSource()

        #expect(source.contains(".lineLimit(nil)"))
        #expect(source.contains(".fixedSize(horizontal: false, vertical: true)"))
    }

    @Test("branch-added token names are constrained instead of overflowing rows")
    func tokenNamesAreConstrained() throws {
        let settingsSource = try passCLISettingsTabSource()
        let statusSource = try sourceFile(named: "Views/Settings/PassCLIStatusRow.swift")

        #expect(settingsSource.contains(".truncationMode(.middle)"))
        #expect(statusSource.contains(".truncationMode(.middle)"))
        #expect(statusSource.contains(".frame(maxWidth: 160"))
    }

    private func passCLISettingsTabSource() throws -> String {
        try sourceFile(named: "Views/Settings/PassCLISettingsTab.swift")
    }

    private func sourceFile(named relativePath: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let projectRoot = testFileURL
            .deletingLastPathComponent() // Quick Access for Pass Tests
            .deletingLastPathComponent() // project root
        let sourceURL = projectRoot
            .appendingPathComponent("Quick Access for Pass")
            .appendingPathComponent(relativePath)

        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
