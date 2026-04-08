import Testing
@testable import Quick_Access_for_Pass

@Suite("PeerVerifier trusted helper matching")
struct PeerVerifierTrustedHelperTests {
    @Test func qaRunMatchesHelperRequirementForSameTeam() {
        #expect(PeerVerifier.isTrustedHelper(identifier: "qa-run", teamID: "TEAM123", selfTeamID: "TEAM123") == true)
    }

    @Test func nonQaRunDoesNotMatchHelperRequirement() {
        #expect(PeerVerifier.isTrustedHelper(identifier: "codes.petr.quick-access-for-pass", teamID: "TEAM123", selfTeamID: "TEAM123") == false)
    }

    @Test func differentTeamDoesNotMatchHelperRequirement() {
        #expect(PeerVerifier.isTrustedHelper(identifier: "qa-run", teamID: "OTHER", selfTeamID: "TEAM123") == false)
    }

    @Test func missingTeamDoesNotMatchHelperRequirement() {
        #expect(PeerVerifier.isTrustedHelper(identifier: "qa-run", teamID: nil as String?, selfTeamID: "TEAM123") == false)
    }
}
