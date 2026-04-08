import Testing
@testable import Quick_Access_for_Pass

@Suite("PeerVerifier")
struct PeerVerifierTests {
    @Test func signedAppIdentifier() {
        let identity = PeerIdentity.signedApp(bundleID: "com.apple.Terminal", teamID: "ABCD123")
        #expect(identity.appIdentifier == "ABCD123.com.apple.Terminal")
    }

    @Test func unverifiedIdentifier() {
        let identity = PeerIdentity.unverified(pid: 42)
        #expect(identity.appIdentifier == "unverified.42")
    }

    @Test func trustedHelperIdentifierIsNil() {
        let identity = PeerIdentity.trustedHelper
        #expect(identity.appIdentifier == nil)
    }

    @Test func verifiedConnectionCarriesPID() {
        let conn = VerifiedConnection(
            fd: 5,
            identity: .signedApp(bundleID: "com.test", teamID: "TEAM1"),
            pid: 1234
        )
        #expect(conn.pid == 1234)
        #expect(conn.fd == 5)
    }
}
