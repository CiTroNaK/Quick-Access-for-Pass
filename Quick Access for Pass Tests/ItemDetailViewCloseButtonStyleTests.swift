import Testing
import Foundation

@Suite("ItemDetailView close button styling")
struct ItemDetailViewCloseButtonStyleTests {
    @Test("close button does not stack explicit circle glass on top of clear glass button style")
    func closeButtonAvoidsStackedCircleGlass() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let projectRoot = testFileURL
            .deletingLastPathComponent() // Quick Access for Pass Tests
            .deletingLastPathComponent() // project root
        let sourceURL = projectRoot
            .appendingPathComponent("Quick Access for Pass")
            .appendingPathComponent("Views/Main/ItemDetailView.swift")

        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("Button(\"Close\", systemImage: \"xmark\", action: onBack)"))
        #expect(source.contains(".appClearGlassButtonStyle()"))
        #expect(source.contains(".appCircleGlassEffect()") == false)
    }
}
