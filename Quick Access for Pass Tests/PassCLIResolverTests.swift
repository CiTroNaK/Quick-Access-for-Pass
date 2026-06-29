import Testing
import Foundation
@testable import Quick_Access_for_Pass

@Suite("PassCLIResolver")
struct PassCLIResolverTests {
    @Test("custom path is authoritative even when system and bundled CLIs exist")
    func customPathWinsWithoutFallback() {
        let resolver = makeResolver(
            executablePaths: [
                "/opt/homebrew/bin/pass-cli",
                "/Applications/Quick Access for Pass.app/Contents/Resources/ProtonPassCLI/2.2.1/pass-cli-arm64"
            ],
            whichPath: "/usr/bin/pass-cli",
            architecture: .arm64
        )

        let selection = resolver.resolve(customPath: "/custom/pass-cli")

        #expect(selection == .custom(path: "/custom/pass-cli"))
        #expect(selection.path == "/custom/pass-cli")
    }

    @Test("blank custom path uses Homebrew before bundled fallback")
    func homebrewWinsInAutoMode() {
        let resolver = makeResolver(
            executablePaths: [
                "/opt/homebrew/bin/pass-cli",
                "/Applications/Quick Access for Pass.app/Contents/Resources/ProtonPassCLI/2.2.1/pass-cli-arm64"
            ],
            whichPath: nil,
            architecture: .arm64
        )

        let selection = resolver.resolve(customPath: "")

        #expect(selection == .installed(path: "/opt/homebrew/bin/pass-cli", fallbackReason: nil))
    }

    @Test("blank custom path uses usr local before bundled fallback")
    func usrLocalWinsInAutoMode() {
        let resolver = makeResolver(
            executablePaths: [
                "/usr/local/bin/pass-cli",
                "/Applications/Quick Access for Pass.app/Contents/Resources/ProtonPassCLI/2.2.1/pass-cli-arm64"
            ],
            whichPath: nil,
            architecture: .arm64
        )

        let selection = resolver.resolve(customPath: nil)

        #expect(selection == .installed(path: "/usr/local/bin/pass-cli", fallbackReason: nil))
    }

    @Test("blank custom path uses local bin before bundled fallback")
    func localBinWinsInAutoMode() {
        let home = NSHomeDirectory()
        let localPath = "\(home)/.local/bin/pass-cli"
        let resolver = makeResolver(
            executablePaths: [
                localPath,
                "/Applications/Quick Access for Pass.app/Contents/Resources/ProtonPassCLI/2.2.1/pass-cli-arm64"
            ],
            whichPath: nil,
            architecture: .arm64
        )

        let selection = resolver.resolve(customPath: nil)

        #expect(selection == .installed(path: localPath, fallbackReason: nil))
    }

    @Test("which result wins over bundled fallback")
    func whichWinsBeforeBundledFallback() {
        let resolver = makeResolver(
            executablePaths: [
                "/usr/bin/pass-cli",
                "/Applications/Quick Access for Pass.app/Contents/Resources/ProtonPassCLI/2.2.1/pass-cli-arm64"
            ],
            whichPath: "/usr/bin/pass-cli",
            architecture: .arm64
        )

        let selection = resolver.resolve(customPath: nil)

        #expect(selection == .installed(path: "/usr/bin/pass-cli", fallbackReason: nil))
    }

    @Test("arm64 bundled fallback is selected when no system CLI exists")
    func arm64BundledFallback() {
        let resolver = makeResolver(
            executablePaths: ["/Applications/Quick Access for Pass.app/Contents/Resources/ProtonPassCLI/2.2.1/pass-cli-arm64"],
            whichPath: nil,
            architecture: .arm64
        )

        let selection = resolver.resolve(customPath: nil)

        #expect(selection == .bundled(
            path: "/Applications/Quick Access for Pass.app/Contents/Resources/ProtonPassCLI/2.2.1/pass-cli-arm64",
            version: "2.2.1",
            architecture: .arm64,
            requested: .latest,
            fallbackReason: nil
        ))
    }

    @Test("x86_64 bundled fallback is selected for x86_64 process architecture")
    func x86BundledFallback() {
        let resolver = makeResolver(
            executablePaths: ["/Applications/Quick Access for Pass.app/Contents/Resources/ProtonPassCLI/2.2.1/pass-cli-x86_64"],
            whichPath: nil,
            architecture: .x8664
        )

        let selection = resolver.resolve(customPath: nil)

        #expect(selection == .bundled(
            path: "/Applications/Quick Access for Pass.app/Contents/Resources/ProtonPassCLI/2.2.1/pass-cli-x86_64",
            version: "2.2.1",
            architecture: .x8664,
            requested: .latest,
            fallbackReason: nil
        ))
    }

    @Test("missing bundled helper falls back to unresolved pass-cli command")
    func missingBundledFallbackReturnsCommandName() {
        let resolver = makeResolver(executablePaths: [], whichPath: nil, architecture: .arm64)

        let selection = resolver.resolve(customPath: nil)

        #expect(selection == .unresolved(command: "pass-cli"))
        #expect(selection.path == "pass-cli")
    }

    @Test("auto uses installed candidate before latest bundled")
    func autoUsesInstalledBeforeLatestBundled() {
        let resolver = makeResolver(
            executablePaths: [
                "/opt/homebrew/bin/pass-cli",
                "/Applications/Quick Access for Pass.app/Contents/Resources/ProtonPassCLI/2.2.1/pass-cli-arm64"
            ],
            whichPath: nil,
            architecture: .arm64,
            manifest: .init(versions: [.init(version: "2.2.1")])
        )

        let selection = resolver.resolve(preference: .auto, customPath: nil)

        #expect(selection == .installed(path: "/opt/homebrew/bin/pass-cli", fallbackReason: nil))
    }

    @Test("installed selection falls back to auto when selected path is missing")
    func missingInstalledSelectionFallsBackToAuto() {
        let resolver = makeResolver(
            executablePaths: ["/Applications/Quick Access for Pass.app/Contents/Resources/ProtonPassCLI/2.2.1/pass-cli-arm64"],
            whichPath: nil,
            architecture: .arm64,
            manifest: .init(versions: [.init(version: "2.2.1")])
        )

        let selection = resolver.resolve(preference: .installed(path: "/missing/pass-cli"), customPath: nil)

        #expect(selection == .bundled(
            path: "/Applications/Quick Access for Pass.app/Contents/Resources/ProtonPassCLI/2.2.1/pass-cli-arm64",
            version: "2.2.1",
            architecture: .arm64,
            requested: .latest,
            fallbackReason: .missingInstalled(path: "/missing/pass-cli")
        ))
    }

    @Test("bundled latest follows newest bundled version")
    func bundledLatestUsesNewestBundledVersion() {
        let resolver = makeResolver(
            executablePaths: [
                "/Applications/Quick Access for Pass.app/Contents/Resources/ProtonPassCLI/2.1.4/pass-cli-arm64",
                "/Applications/Quick Access for Pass.app/Contents/Resources/ProtonPassCLI/2.2.1/pass-cli-arm64"
            ],
            whichPath: nil,
            architecture: .arm64,
            manifest: .init(versions: [.init(version: "2.1.4"), .init(version: "2.2.1")])
        )

        let selection = resolver.resolve(preference: .bundled(.latest), customPath: nil)

        #expect(selection.path.hasSuffix("/ProtonPassCLI/2.2.1/pass-cli-arm64"))
    }

    @Test("missing exact bundled version falls back through auto")
    func missingExactBundledFallsBackThroughAuto() {
        let resolver = makeResolver(
            executablePaths: [
                "/opt/homebrew/bin/pass-cli",
                "/Applications/Quick Access for Pass.app/Contents/Resources/ProtonPassCLI/2.2.1/pass-cli-arm64"
            ],
            whichPath: nil,
            architecture: .arm64,
            manifest: .init(versions: [.init(version: "2.2.1")])
        )

        let selection = resolver.resolve(preference: .bundled(.version("2.1.4")), customPath: nil)

        #expect(selection == .installed(
            path: "/opt/homebrew/bin/pass-cli",
            fallbackReason: .missingBundled(version: "2.1.4")
        ))
    }

    @Test("custom selection is authoritative and does not fallback")
    func customSelectionIsAuthoritative() {
        let resolver = makeResolver(
            executablePaths: ["/Applications/Quick Access for Pass.app/Contents/Resources/ProtonPassCLI/2.2.1/pass-cli-arm64"],
            whichPath: nil,
            architecture: .arm64,
            manifest: .init(versions: [.init(version: "2.2.1")])
        )

        let selection = resolver.resolve(preference: .custom, customPath: "/missing/custom-pass-cli")

        #expect(selection == .custom(path: "/missing/custom-pass-cli"))
    }

    private func makeResolver(
        executablePaths: Set<String>,
        whichPath: String?,
        architecture: PassCLIArchitecture,
        manifest: PassCLIBundledManifest = .init(versions: [.init(version: "2.2.1")])
    ) -> PassCLIResolver {
        PassCLIResolver(
            fileSystem: StubExecutableFileSystem(executablePaths: executablePaths),
            which: StubWhichResolver(path: whichPath),
            bundleURL: URL(fileURLWithPath: "/Applications/Quick Access for Pass.app"),
            architecture: architecture,
            manifest: manifest
        )
    }
}

private struct StubExecutableFileSystem: ExecutableFileChecking {
    let executablePaths: Set<String>

    nonisolated func isExecutableFile(atPath path: String) -> Bool {
        executablePaths.contains(path)
    }
}

private struct StubWhichResolver: WhichResolving {
    let path: String?

    nonisolated func find(_ executableName: String) -> String? {
        path
    }
}
