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

    @Test("folders require CLI 2.5.0 or newer", arguments: [
        ("2.4.2", false), ("2.5.0", true), ("2.5.1", true),
        ("2.6.0", true), ("3.0.0", true), ("garbage", false), ("", false)
    ])
    func foldersRequire250(raw: String, expected: Bool) {
        #expect(PassCLICapabilities(rawVersionString: raw).supportsFolders == expected)
        #expect(!PassCLICapabilities(version: nil).supportsFolders)
        #expect(PassCLICapabilities.minimumFoldersVersion == PassCLIVersion(major: 2, minor: 5, patch: 0))
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
