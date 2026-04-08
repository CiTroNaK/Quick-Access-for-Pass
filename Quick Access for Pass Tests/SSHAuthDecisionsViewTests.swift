import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("SSH remembered decisions view")
struct SSHAuthDecisionsViewTests {
    @Test func presentationBuildsSharedRowConfigForCommandScopedDecision() {
        let decision = SSHAuthDecision(
            appIdentifier: "com.mitchellh.ghostty:github.com:git fetch --all",
            keyFingerprint: "SHA256:abc",
            expiresAt: .distantFuture,
            appTeamID: nil
        )

        let presentation = SSHDecisionRowPresentation(decision: decision)
        let config = presentation.rowConfig(relativeExpiration: "in 1 hour")

        #expect(config.bundleID == "com.mitchellh.ghostty")
        #expect(config.primaryText == "git fetch --all")
        #expect(config.secondaryText == "github.com · in 1 hour")
        #expect(config.removeHelpText == "Remove (will ask again on next request)")
    }
}
