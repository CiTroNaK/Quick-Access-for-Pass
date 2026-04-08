import Testing
import Security
@testable import Quick_Access_for_Pass

@Suite("PeerVerifier signing info extraction")
struct PeerVerifierSigningInfoTests {
    @Test func helperTeamFallsBackToApplicationIdentifierPrefix() {
        let signingInfo: [String: Any] = [
            kSecCodeInfoIdentifier as String: "qa-run",
            kSecCodeInfoEntitlementsDict as String: [
                "com.apple.application-identifier": "H23TXL6LPT."
            ]
        ]

        let identity = PeerVerifier.resolveSigningIdentity(from: signingInfo)

        #expect(identity?.identifier == "qa-run")
        #expect(identity?.teamID == "H23TXL6LPT")
    }

    @Test func teamIdentifierPrefersExplicitEntitlement() {
        let signingInfo: [String: Any] = [
            kSecCodeInfoIdentifier as String: "codes.petr.quick-access-for-pass",
            kSecCodeInfoEntitlementsDict as String: [
                "com.apple.developer.team-identifier": "H23TXL6LPT",
                "com.apple.application-identifier": "H23TXL6LPT.codes.petr.quick-access-for-pass"
            ]
        ]

        let identity = PeerVerifier.resolveSigningIdentity(from: signingInfo)

        #expect(identity?.identifier == "codes.petr.quick-access-for-pass")
        #expect(identity?.teamID == "H23TXL6LPT")
    }
}
