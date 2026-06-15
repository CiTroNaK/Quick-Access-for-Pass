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
                "/Applications/Quick Access for Pass.app/Contents/Helpers/pass-cli-arm64"
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
                "/Applications/Quick Access for Pass.app/Contents/Helpers/pass-cli-arm64"
            ],
            whichPath: nil,
            architecture: .arm64
        )

        let selection = resolver.resolve(customPath: "")

        #expect(selection == .system(path: "/opt/homebrew/bin/pass-cli"))
    }

    @Test("blank custom path uses usr local before bundled fallback")
    func usrLocalWinsInAutoMode() {
        let resolver = makeResolver(
            executablePaths: [
                "/usr/local/bin/pass-cli",
                "/Applications/Quick Access for Pass.app/Contents/Helpers/pass-cli-arm64"
            ],
            whichPath: nil,
            architecture: .arm64
        )

        let selection = resolver.resolve(customPath: nil)

        #expect(selection == .system(path: "/usr/local/bin/pass-cli"))
    }

    @Test("blank custom path uses local bin before bundled fallback")
    func localBinWinsInAutoMode() {
        let home = NSHomeDirectory()
        let localPath = "\(home)/.local/bin/pass-cli"
        let resolver = makeResolver(
            executablePaths: [
                localPath,
                "/Applications/Quick Access for Pass.app/Contents/Helpers/pass-cli-arm64"
            ],
            whichPath: nil,
            architecture: .arm64
        )

        let selection = resolver.resolve(customPath: nil)

        #expect(selection == .system(path: localPath))
    }

    @Test("which result wins over bundled fallback")
    func whichWinsBeforeBundledFallback() {
        let resolver = makeResolver(
            executablePaths: [
                "/usr/bin/pass-cli",
                "/Applications/Quick Access for Pass.app/Contents/Helpers/pass-cli-arm64"
            ],
            whichPath: "/usr/bin/pass-cli",
            architecture: .arm64
        )

        let selection = resolver.resolve(customPath: nil)

        #expect(selection == .system(path: "/usr/bin/pass-cli"))
    }

    @Test("arm64 bundled fallback is selected when no system CLI exists")
    func arm64BundledFallback() {
        let resolver = makeResolver(
            executablePaths: ["/Applications/Quick Access for Pass.app/Contents/Helpers/pass-cli-arm64"],
            whichPath: nil,
            architecture: .arm64
        )

        let selection = resolver.resolve(customPath: nil)

        #expect(selection == .bundled(
            path: "/Applications/Quick Access for Pass.app/Contents/Helpers/pass-cli-arm64",
            architecture: .arm64
        ))
    }

    @Test("x86_64 bundled fallback is selected for x86_64 process architecture")
    func x86BundledFallback() {
        let resolver = makeResolver(
            executablePaths: ["/Applications/Quick Access for Pass.app/Contents/Helpers/pass-cli-x86_64"],
            whichPath: nil,
            architecture: .x8664
        )

        let selection = resolver.resolve(customPath: nil)

        #expect(selection == .bundled(
            path: "/Applications/Quick Access for Pass.app/Contents/Helpers/pass-cli-x86_64",
            architecture: .x8664
        ))
    }

    @Test("missing bundled helper falls back to unresolved pass-cli command")
    func missingBundledFallbackReturnsCommandName() {
        let resolver = makeResolver(executablePaths: [], whichPath: nil, architecture: .arm64)

        let selection = resolver.resolve(customPath: nil)

        #expect(selection == .unresolved(command: "pass-cli"))
        #expect(selection.path == "pass-cli")
    }

    private func makeResolver(
        executablePaths: Set<String>,
        whichPath: String?,
        architecture: PassCLIArchitecture
    ) -> PassCLIResolver {
        PassCLIResolver(
            fileSystem: StubExecutableFileSystem(executablePaths: executablePaths),
            which: StubWhichResolver(path: whichPath),
            bundleURL: URL(fileURLWithPath: "/Applications/Quick Access for Pass.app"),
            architecture: architecture
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
