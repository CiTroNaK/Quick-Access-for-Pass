import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Run authorization identity")
struct RunAuthorizationIdentityTests {
    @Test("exact digest validation accepts only lowercase ASCII hex")
    func exactDigestValidation() {
        let digest = String(repeating: "a", count: 64)
        #expect(RunAuthorizationIdentity(exactDigest: digest)?.matchType == .exactArgumentsV1)
        #expect(RunAuthorizationIdentity(exactDigest: digest)?.matchValue == digest)
        for malformed in [
            String(repeating: "A", count: 64),
            String(repeating: "g", count: 64),
            String(repeating: "a", count: 63),
            String(repeating: "a", count: 65),
            String(repeating: "a", count: 63) + "é",
            String(repeating: "a", count: 63) + "\0"
        ] {
            #expect(RunAuthorizationIdentity(exactDigest: malformed) == nil)
        }
    }

    @Test("identity equality includes type and literal value")
    func identityEquality() {
        let digest = String(repeating: "b", count: 64)
        let exact = RunAuthorizationIdentity(exactDigest: digest)
        #expect(exact == RunAuthorizationIdentity(exactDigest: digest))
        #expect(exact != RunAuthorizationIdentity(prefix: digest))
        #expect(RunAuthorizationIdentity(prefix: "  tool  ") == RunAuthorizationIdentity(prefix: "  tool  "))
        #expect(RunAuthorizationIdentity(prefix: "  tool  ").matchValue == "  tool  ")
        #expect(RunAuthorizationIdentity(prefix: "tool") != RunAuthorizationIdentity(prefix: "tool "))
    }
}
