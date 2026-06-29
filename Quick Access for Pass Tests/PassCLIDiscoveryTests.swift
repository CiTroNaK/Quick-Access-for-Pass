import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Pass CLI discovery")
struct PassCLIDiscoveryTests {
    @Test("discovers installed candidates in stable order and keeps duplicate versions as separate paths")
    func discoversInstalledCandidates() async {
        let discovery = PassCLIDiscovery(
            fileSystem: StubExecutableFileSystem(executablePaths: [
                "/opt/homebrew/bin/pass-cli",
                "/usr/local/bin/pass-cli"
            ]),
            which: StubWhichResolver(path: "/usr/local/bin/pass-cli"),
            bundleURL: URL(fileURLWithPath: "/Applications/Quick Access for Pass.app"),
            architecture: .arm64,
            versionProbe: StubPassCLIVersionProbe(versions: [
                "/opt/homebrew/bin/pass-cli": "2.2.1",
                "/usr/local/bin/pass-cli": "2.2.1"
            ])
        )

        let candidates = await discovery.installedCandidates()

        #expect(candidates.map(\.path) == [
            "/opt/homebrew/bin/pass-cli",
            "/usr/local/bin/pass-cli"
        ])
        #expect(candidates.map(\.displayVersion) == ["2.2.1", "2.2.1"])
    }

    @Test("discovers bundled versions newest first for current architecture")
    func discoversBundledVersionsNewestFirst() {
        let discovery = PassCLIDiscovery(
            fileSystem: StubExecutableFileSystem(executablePaths: [
                "/Applications/Quick Access for Pass.app/Contents/Resources/ProtonPassCLI/2.1.4/pass-cli-arm64",
                "/Applications/Quick Access for Pass.app/Contents/Resources/ProtonPassCLI/2.2.1/pass-cli-arm64"
            ]),
            which: StubWhichResolver(path: nil),
            bundleURL: URL(fileURLWithPath: "/Applications/Quick Access for Pass.app"),
            architecture: .arm64,
            manifest: .init(versions: [
                .init(version: "2.1.4"),
                .init(version: "2.2.1")
            ])
        )

        let bundled = discovery.bundledCandidates()

        #expect(bundled.map(\.version.description) == ["2.2.1", "2.1.4"])
        #expect(bundled.first?.isLatest == true)
    }

    @Test("resolves bundled latest and exact version paths")
    func resolvesBundledPaths() {
        let discovery = PassCLIDiscovery(
            fileSystem: StubExecutableFileSystem(executablePaths: [
                "/Applications/Quick Access for Pass.app/Contents/Resources/ProtonPassCLI/2.1.4/pass-cli-arm64",
                "/Applications/Quick Access for Pass.app/Contents/Resources/ProtonPassCLI/2.2.1/pass-cli-arm64"
            ]),
            which: StubWhichResolver(path: nil),
            bundleURL: URL(fileURLWithPath: "/Applications/Quick Access for Pass.app"),
            architecture: .arm64,
            manifest: .init(versions: [
                .init(version: "2.1.4"),
                .init(version: "2.2.1")
            ])
        )

        #expect(discovery.resolveBundled(.latest)?.version.description == "2.2.1")
        #expect(discovery.resolveBundled(.version("2.1.4"))?.version.description == "2.1.4")
        #expect(discovery.resolveBundled(.version("9.9.9")) == nil)
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

private struct StubPassCLIVersionProbe: PassCLIVersionProbing {
    let versions: [String: String]

    func version(atPath path: String) async -> String? {
        versions[path]
    }
}
