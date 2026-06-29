import Foundation

nonisolated struct PassCLIInstalledCandidate: Sendable, Equatable, Identifiable {
    let path: String
    let displayVersion: String?

    var id: String { path }
}

nonisolated struct PassCLIBundledCandidate: Sendable, Equatable, Identifiable {
    let version: PassCLIVersion
    let path: String
    let architecture: PassCLIArchitecture
    let isLatest: Bool

    var id: String { version.description }
}

nonisolated struct PassCLIBundledManifest: Sendable, Decodable, Equatable {
    struct Version: Sendable, Decodable, Equatable {
        let version: String
    }

    let versions: [Version]

    static func load(from url: URL? = Bundle.main.url(forResource: "proton-pass-cli", withExtension: "json")) -> PassCLIBundledManifest {
        guard let url else { return PassCLIBundledManifest(versions: []) }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(PassCLIBundledManifest.self, from: data)
        } catch {
            return PassCLIBundledManifest(versions: [])
        }
    }
}

protocol PassCLIVersionProbing: Sendable {
    func version(atPath path: String) async -> String?
}

nonisolated struct LivePassCLIVersionProbe: PassCLIVersionProbing {
    let runner: any CLIRunning

    init(runner: any CLIRunning = LiveCLIRunner()) {
        self.runner = runner
    }

    func version(atPath path: String) async -> String? {
        await PassCLISanityCheck.fetchVersion(cliPath: path, runner: runner)
    }
}

nonisolated struct PassCLIDiscovery: Sendable {
    private let fileSystem: any ExecutableFileChecking
    private let which: any WhichResolving
    private let bundleURL: URL
    private let architecture: PassCLIArchitecture
    private let manifest: PassCLIBundledManifest
    private let versionProbe: any PassCLIVersionProbing

    init(
        fileSystem: any ExecutableFileChecking = LiveExecutableFileSystem(),
        which: any WhichResolving = LiveWhichResolver(),
        bundleURL: URL = Bundle.main.bundleURL,
        architecture: PassCLIArchitecture = .current,
        manifest: PassCLIBundledManifest = .load(),
        versionProbe: any PassCLIVersionProbing = LivePassCLIVersionProbe()
    ) {
        self.fileSystem = fileSystem
        self.which = which
        self.bundleURL = bundleURL
        self.architecture = architecture
        self.manifest = manifest
        self.versionProbe = versionProbe
    }

    func installedCandidatePaths() -> [String] {
        var paths: [String] = systemCandidates.filter { fileSystem.isExecutableFile(atPath: $0) }
        if let path = which.find("pass-cli"),
           fileSystem.isExecutableFile(atPath: path),
           paths.contains(path) == false {
            paths.append(path)
        }
        return paths
    }

    func installedCandidates() async -> [PassCLIInstalledCandidate] {
        var candidates: [PassCLIInstalledCandidate] = []
        for path in installedCandidatePaths() {
            guard Task.isCancelled == false else { return candidates }
            candidates.append(PassCLIInstalledCandidate(
                path: path,
                displayVersion: await versionProbe.version(atPath: path)
            ))
        }
        return candidates
    }

    func bundledCandidates() -> [PassCLIBundledCandidate] {
        let parsed = manifest.versions.compactMap { entry -> (PassCLIVersion, String)? in
            guard let version = PassCLIVersion(entry.version) else { return nil }
            let path = bundledHelperPath(version: version.description, architecture: architecture)
            guard fileSystem.isExecutableFile(atPath: path) else { return nil }
            return (version, path)
        }.sorted { $0.0 > $1.0 }

        guard let latest = parsed.first?.0 else { return [] }
        return parsed.map { version, path in
            PassCLIBundledCandidate(
                version: version,
                path: path,
                architecture: architecture,
                isLatest: version == latest
            )
        }
    }

    func resolveBundled(_ selection: BundledPassCLISelection) -> PassCLIBundledCandidate? {
        let candidates = bundledCandidates()
        switch selection {
        case .latest:
            return candidates.first
        case .version(let rawVersion):
            return candidates.first { $0.version.description == rawVersion }
        }
    }

    func latestBundledCandidate() -> PassCLIBundledCandidate? {
        bundledCandidates().first
    }

    private var systemCandidates: [String] {
        [
            "/opt/homebrew/bin/pass-cli",
            "/usr/local/bin/pass-cli",
            NSString(string: "~/.local/bin/pass-cli").expandingTildeInPath
        ]
    }

    private func bundledHelperPath(version: String, architecture: PassCLIArchitecture) -> String {
        bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Resources")
            .appendingPathComponent("ProtonPassCLI")
            .appendingPathComponent(version)
            .appendingPathComponent("pass-cli-\(architecture.rawValue)")
            .path
    }
}
