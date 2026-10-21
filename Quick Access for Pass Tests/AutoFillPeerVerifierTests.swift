import Darwin
import Foundation
import Security
import Testing
@testable import Quick_Access_for_Pass

@Suite("AutoFill peer verifier")
struct AutoFillPeerVerifierTests {
    private let expectedIdentifier = AutoFillConstants.extensionBundleIdentifier
    private let expectedTeamID = "H23TXL6LPT"

    @Test("accepts only the expected audit-bound signed identifier and certificate team")
    func acceptsExpectedIdentity() throws {
        let fixture = FakeSecurityIdentity(
            identifier: expectedIdentifier,
            certificateTeamID: expectedTeamID,
            isAppleAnchoredAndSigned: true
        )
        let verifier = makeVerifier(identity: fixture)

        let peer = try verifier.verify(
            fd: 17,
            expectedIdentifier: expectedIdentifier,
            teamID: expectedTeamID
        )

        #expect(peer == VerifiedAutoFillPeer(
            fileDescriptor: 17,
            identifier: expectedIdentifier,
            teamID: expectedTeamID
        ))
    }

    @Test("the same audit-bound verifier accepts the exact host identity in the reverse direction")
    func acceptsExpectedHostIdentity() throws {
        let hostIdentifier = AutoFillConstants.hostBundleIdentifier
        let verifier = makeVerifier(identity: .init(
            identifier: hostIdentifier,
            certificateTeamID: expectedTeamID,
            isAppleAnchoredAndSigned: true
        ))

        let peer = try verifier.verify(
            fd: 18,
            expectedIdentifier: hostIdentifier,
            teamID: expectedTeamID
        )

        #expect(peer.identifier == hostIdentifier)
        #expect(peer.teamID == expectedTeamID)
    }

    @Test("rejects a signed same-team peer with the wrong exact identifier")
    func rejectsWrongSameTeamIdentifier() {
        let verifier = makeVerifier(identity: .init(
            identifier: "codes.petr.quick-access-for-pass.not-autofill",
            certificateTeamID: expectedTeamID,
            isAppleAnchoredAndSigned: true
        ))

        #expect(throws: AutoFillPeerVerificationError.invalidPeer) {
            try verifier.verify(fd: 17, expectedIdentifier: expectedIdentifier, teamID: expectedTeamID)
        }
    }

    @Test("rejects the expected identifier signed by the wrong certificate team")
    func rejectsWrongCertificateTeam() {
        let verifier = makeVerifier(identity: .init(
            identifier: expectedIdentifier,
            certificateTeamID: "WRONGTEAM1",
            isAppleAnchoredAndSigned: true
        ))

        #expect(throws: AutoFillPeerVerificationError.invalidPeer) {
            try verifier.verify(fd: 17, expectedIdentifier: expectedIdentifier, teamID: expectedTeamID)
        }
    }

    @Test("rejects an unsigned peer")
    func rejectsUnsignedPeer() {
        let verifier = makeVerifier(identity: .init(
            identifier: expectedIdentifier,
            certificateTeamID: expectedTeamID,
            isAppleAnchoredAndSigned: false
        ))

        #expect(throws: AutoFillPeerVerificationError.invalidPeer) {
            try verifier.verify(fd: 17, expectedIdentifier: expectedIdentifier, teamID: expectedTeamID)
        }
    }

    @Test("fails closed when LOCAL_PEERTOKEN lookup fails")
    func rejectsPeerTokenLookupFailure() {
        let verifier = AutoFillPeerVerifier(
            peerTokenLookup: { _ in throw AutoFillPeerVerificationError.peerTokenUnavailable },
            securityValidation: { _, _ in }
        )

        #expect(throws: AutoFillPeerVerificationError.peerTokenUnavailable) {
            try verifier.verify(fd: 17, expectedIdentifier: expectedIdentifier, teamID: expectedTeamID)
        }
    }

    @Test("fails closed when audit-bound Security guest lookup fails")
    func rejectsSecurityLookupFailure() {
        let verifier = AutoFillPeerVerifier(
            peerTokenLookup: { _ in Self.fakeAuditToken },
            securityValidation: { _, _ in
                throw AutoFillPeerVerificationError.guestLookupFailed(errSecCSNoSuchCode)
            }
        )

        #expect(throws: AutoFillPeerVerificationError.guestLookupFailed(errSecCSNoSuchCode)) {
            try verifier.verify(fd: 17, expectedIdentifier: expectedIdentifier, teamID: expectedTeamID)
        }
    }

    @Test("rejects malformed audit tokens before Security interpretation")
    func rejectsMalformedAuditToken() {
        let verifier = AutoFillPeerVerifier(
            peerTokenLookup: { _ in Data([0x01]) },
            securityValidation: { _, _ in Issue.record("Security must not receive a malformed token") }
        )

        #expect(throws: AutoFillPeerVerificationError.invalidAuditToken) {
            try verifier.verify(fd: 17, expectedIdentifier: expectedIdentifier, teamID: expectedTeamID)
        }
    }

    @Test("requirement pins Apple generic anchor, exact identifier, and certificate leaf OU")
    func requirementPinsAllIdentityParts() throws {
        let requirement = try AutoFillPeerVerifier.requirementString(
            identifier: expectedIdentifier,
            teamID: expectedTeamID
        )

        #expect(requirement == "anchor apple generic and identifier \"codes.petr.quick-access-for-pass.autofill\" and certificate leaf[subject.OU] = \"H23TXL6LPT\"")
    }

    private func makeVerifier(identity: FakeSecurityIdentity) -> AutoFillPeerVerifier {
        AutoFillPeerVerifier(
            peerTokenLookup: { _ in Self.fakeAuditToken },
            securityValidation: { _, requirement in
                guard identity.isAppleAnchoredAndSigned,
                      requirement.contains("identifier \"\(identity.identifier)\""),
                      requirement.contains("certificate leaf[subject.OU] = \"\(identity.certificateTeamID)\"") else {
                    throw AutoFillPeerVerificationError.invalidPeer
                }
            }
        )
    }

    private static let fakeAuditToken = Data(repeating: 0xA5, count: MemoryLayout<audit_token_t>.size)
}

private struct FakeSecurityIdentity: Sendable {
    let identifier: String
    let certificateTeamID: String
    let isAppleAnchoredAndSigned: Bool
}
