import Testing
@testable import Quick_Access_for_Pass

@Suite("Pass CLI version parsing")
struct PassCLIVersionTests {
    @Test("parses plain semantic versions")
    func parsesPlainVersion() throws {
        let version = try #require(PassCLIVersion("2.2.1"))
        #expect(version.major == 2)
        #expect(version.minor == 2)
        #expect(version.patch == 1)
        #expect(version.description == "2.2.1")
    }

    @Test("parses pass-cli output with product prefix and metadata")
    func parsesCLIOutput() throws {
        #expect(PassCLIVersion("pass-cli 2.2.1") == PassCLIVersion(major: 2, minor: 2, patch: 1))
        #expect(PassCLIVersion("Proton Pass CLI 2.1.4 (abcdef)") == PassCLIVersion(major: 2, minor: 1, patch: 4))
    }

    @Test("compares semantic versions")
    func comparesVersions() throws {
        let older = try #require(PassCLIVersion("2.1.4"))
        let newer = try #require(PassCLIVersion("2.2.1"))

        #expect(older < newer)
        #expect(newer >= older)
    }

    @Test("rejects strings without a semantic version")
    func rejectsInvalidVersions() {
        #expect(PassCLIVersion("development build") == nil)
        #expect(PassCLIVersion("") == nil)
    }
}
