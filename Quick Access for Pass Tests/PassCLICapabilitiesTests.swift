import Testing
@testable import Quick_Access_for_Pass

@Suite("Pass CLI capabilities")
struct PassCLICapabilitiesTests {
    @Test("missing version has no optional capabilities")
    func missingVersionHasNoOptionalCapabilities() {
        let capabilities = PassCLICapabilities(version: nil)

        #expect(capabilities.version == nil)
        #expect(capabilities.supportsShowSecrets == false)
        #expect(capabilities.supportsSessionLocking == false)
    }

    @Test(
        "session locking starts at pass-cli 2.2.2",
        arguments: [
            (rawVersion: "2.2.1", expected: false),
            (rawVersion: "2.2.2", expected: true),
            (rawVersion: "2.3.3", expected: true)
        ]
    )
    func sessionLockingStartsAt222(rawVersion: String, expected: Bool) throws {
        let version = try #require(PassCLIVersion(rawVersion))
        let capabilities = PassCLICapabilities(version: version)

        #expect(capabilities.supportsSessionLocking == expected)
    }

    @Test(
        "show secrets starts at pass-cli 2.0.3",
        arguments: [
            (rawVersion: "2.0.2", expected: false),
            (rawVersion: "2.0.3", expected: true),
            (rawVersion: "2.1.0", expected: true)
        ]
    )
    func showSecretsStartsAt203(rawVersion: String, expected: Bool) throws {
        let version = try #require(PassCLIVersion(rawVersion))
        let capabilities = PassCLICapabilities(version: version)

        #expect(capabilities.supportsShowSecrets == expected)
    }

    @Test("parses capabilities from raw version string")
    func parsesFromRawVersionString() {
        let capabilities = PassCLICapabilities(rawVersionString: "Proton Pass CLI 2.3.3 (abcdef)")

        #expect(capabilities.version?.description == "2.3.3")
        #expect(capabilities.supportsShowSecrets)
        #expect(capabilities.supportsSessionLocking)
    }

    @Test("unparsable version fails optional capabilities closed")
    func unparsableVersionFailsClosed() {
        let capabilities = PassCLICapabilities(rawVersionString: "development build")

        #expect(capabilities.version == nil)
        #expect(capabilities.supportsShowSecrets == false)
        #expect(capabilities.supportsSessionLocking == false)
    }
}
