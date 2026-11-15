import Foundation
import Security
import Testing
@testable import Quick_Access_for_Pass

@Suite struct HerdrCodeSignatureVerifierTests {
    private static let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")

    @Test func currentTestProcessIsNotCore() {
        #expect(!LiveHerdrCodeSignatureVerifier(locateApp: { nil }).isVerifiedCore(pid: getpid()))
    }

    @Test func peerVerdictIsCachedPerAuditToken() throws {
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &token) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        try #require(status == KERN_SUCCESS)
        let verifier = LiveHerdrCodeSignatureVerifier()
        #expect(!verifier.isVerifiedCore(auditToken: token))
        #expect(!verifier.isVerifiedCore(auditToken: token))
        #expect(verifier.peerValidationCount == 1)
    }

    @Test func dynamicValidityFlagsAreAccepted() throws {
        var code: SecCode?
        try #require(SecCodeCopySelf([], &code) == errSecSuccess)
        let status = SecCodeCheckValidity(try #require(code), LiveHerdrCodeSignatureVerifier.dynamicValidityFlags, nil)
        #expect(status != errSecCSInvalidFlags)
    }

    @Test func nonexistentPIDIsNotCore() {
        #expect(!LiveHerdrCodeSignatureVerifier(locateApp: { nil }).isVerifiedCore(pid: .max))
    }

    @Test func teamClauseIsEnforced() {
        let wrongTeam = LiveHerdrCodeSignatureVerifier(
            appRequirement: #"identifier "com.apple.calculator" and anchor apple generic and certificate leaf[subject.OU] = "2W9652Q7QR""#,
            locateApp: { Self.calculator })
        #expect(wrongTeam.verifiedHerdrAppURL() == nil)
        let matching = LiveHerdrCodeSignatureVerifier(appRequirement: #"identifier "com.apple.calculator" and anchor apple"#,
                                                      locateApp: { Self.calculator })
        #expect(matching.verifiedHerdrAppURL() == Self.calculator.standardizedFileURL)
    }

    @Test func appVerdictIsCached() {
        let verifier = LiveHerdrCodeSignatureVerifier(appRequirement: #"identifier "com.apple.calculator" and anchor apple"#,
                                                      locateApp: { Self.calculator })
        _ = verifier.verifiedHerdrAppURL()
        _ = verifier.verifiedHerdrAppURL()
        #expect(verifier.validationCount == 1)
    }

    @Test func appLocatorNilIsNil() {
        #expect(LiveHerdrCodeSignatureVerifier(locateApp: { nil }).verifiedHerdrAppURL() == nil)
    }

    @Test(arguments: [LiveHerdrCodeSignatureVerifier.coreRequirement, LiveHerdrCodeSignatureVerifier.appRequirement])
    func requirementsCompile(_ text: String) {
        var requirement: SecRequirement?
        #expect(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess)
    }

    @Test func workingDirectoryOfSelf() throws {
        let path = try #require(RequesterProcessCapture.readWorkingDirectory(getpid()))
        #expect(URL(fileURLWithPath: path).resolvingSymlinksInPath()
            == URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath())
    }

    @Test func nonexistentPIDHasNoWorkingDirectory() {
        #expect(RequesterProcessCapture.readWorkingDirectory(.max) == nil)
    }
}
