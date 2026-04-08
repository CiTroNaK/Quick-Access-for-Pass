import Testing
@testable import Quick_Access_for_Pass

@Suite("Remembered decision row")
struct RememberedDecisionRowTests {
    @Test func configCarriesBundleAndTextFields() {
        let config = RememberedDecisionRowConfig(
            bundleID: "com.apple.Terminal",
            primaryText: "git pull",
            secondaryText: "Production · in 1 hour",
            removeHelpText: "Remove (will ask again on next request)"
        )

        #expect(config.bundleID == "com.apple.Terminal")
        #expect(config.primaryText == "git pull")
        #expect(config.secondaryText == "Production · in 1 hour")
        #expect(config.removeHelpText == "Remove (will ask again on next request)")
    }
}
