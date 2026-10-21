import Foundation
import Testing

@Suite("Host app Info.plist")
struct AppInfoPlistTests {
    @Test("declares runtime bundle identity and executable")
    func declaresRuntimeBundleIdentityAndExecutable() throws {
        for infoPlistURL in [
            repositoryRoot.appendingPathComponent("Quick Access for Pass/Info.plist"),
            repositoryRoot.appendingPathComponent("Quick Access AutoFill/Info.plist"),
        ] {
            let data = try Data(contentsOf: infoPlistURL)
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            let values = try #require(plist as? [String: Any])

            #expect(values["CFBundleIdentifier"] as? String == "$(PRODUCT_BUNDLE_IDENTIFIER)")
            #expect(values["CFBundleExecutable"] as? String == "$(EXECUTABLE_NAME)")
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
