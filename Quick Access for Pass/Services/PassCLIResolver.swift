import Foundation

nonisolated enum PassCLIArchitecture: String, Sendable, Equatable {
    case arm64
    case x8664 = "x86_64"

    static var current: PassCLIArchitecture {
        #if arch(arm64)
        .arm64
        #else
        .x8664
        #endif
    }
}

nonisolated enum PassCLIResolutionFallback: Sendable, Equatable {
    case missingInstalled(path: String)
    case missingBundled(version: String)
}

nonisolated enum PassCLISelection: Sendable, Equatable {
    case custom(path: String)
    case installed(path: String, fallbackReason: PassCLIResolutionFallback?)
    case bundled(
        path: String,
        version: String,
        architecture: PassCLIArchitecture,
        requested: BundledPassCLISelection,
        fallbackReason: PassCLIResolutionFallback?
    )
    case unresolved(command: String)

    var path: String {
        switch self {
        case .custom(let path), .installed(let path, _), .bundled(let path, _, _, _, _):
            path
        case .unresolved(let command):
            command
        }
    }

    var sourceLabel: String {
        switch self {
        case .custom(let path):
            "Custom: \(path)"
        case .installed(let path, _):
            "Installed: \(path)"
        case .bundled(_, let version, let architecture, let requested, _):
            switch requested {
            case .latest:
                "Bundled: pass-cli \(version) (latest, \(architecture.rawValue))"
            case .version:
                "Bundled: pass-cli \(version) (\(architecture.rawValue))"
            }
        case .unresolved:
            "Not found"
        }
    }

    var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    var isBundled: Bool {
        if case .bundled = self { return true }
        return false
    }

    var fallbackReason: PassCLIResolutionFallback? {
        switch self {
        case .installed(_, let reason): return reason
        case .bundled(_, _, _, _, let reason): return reason
        case .custom, .unresolved: return nil
        }
    }
}

protocol ExecutableFileChecking: Sendable {
    nonisolated func isExecutableFile(atPath path: String) -> Bool
}

nonisolated struct LiveExecutableFileSystem: ExecutableFileChecking {
    nonisolated func isExecutableFile(atPath path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}

protocol WhichResolving: Sendable {
    nonisolated func find(_ executableName: String) -> String?
}

nonisolated struct LiveWhichResolver: WhichResolving {
    nonisolated func find(_ executableName: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [executableName]
        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == false ? output : nil
    }
}

nonisolated struct PassCLIResolver: Sendable {
    private let fileSystem: any ExecutableFileChecking
    private let discovery: PassCLIDiscovery

    init(
        fileSystem: any ExecutableFileChecking = LiveExecutableFileSystem(),
        which: any WhichResolving = LiveWhichResolver(),
        bundleURL: URL = Bundle.main.bundleURL,
        architecture: PassCLIArchitecture = .current,
        manifest: PassCLIBundledManifest = .load()
    ) {
        self.fileSystem = fileSystem
        self.discovery = PassCLIDiscovery(
            fileSystem: fileSystem,
            which: which,
            bundleURL: bundleURL,
            architecture: architecture,
            manifest: manifest
        )
    }

    var latestBundledVersion: PassCLIVersion? {
        discovery.latestBundledCandidate()?.version
    }

    func resolve(preference: PassCLISelectionPreference, customPath: String?) -> PassCLISelection {
        switch preference {
        case .custom:
            let path = customPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return path.isEmpty ? .unresolved(command: "pass-cli") : .custom(path: path)
        case .installed(let path):
            if fileSystem.isExecutableFile(atPath: path) {
                return .installed(path: path, fallbackReason: nil)
            }
            return resolveAuto(fallbackReason: .missingInstalled(path: path))
        case .bundled(let requested):
            if let bundled = discovery.resolveBundled(requested) {
                return .bundled(
                    path: bundled.path,
                    version: bundled.version.description,
                    architecture: bundled.architecture,
                    requested: requested,
                    fallbackReason: nil
                )
            }
            return resolveAuto(fallbackReason: .missingBundled(version: requested.rawValue))
        case .auto:
            return resolveAuto(fallbackReason: nil)
        }
    }

    func resolve(customPath: String?) -> PassCLISelection {
        let preference: PassCLISelectionPreference = {
            let trimmed = customPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? .auto : .custom
        }()
        return resolve(preference: preference, customPath: customPath)
    }

    private func resolveAuto(fallbackReason: PassCLIResolutionFallback?) -> PassCLISelection {
        for path in discovery.installedCandidatePaths() {
            return .installed(path: path, fallbackReason: fallbackReason)
        }
        return resolveLatestBundled(fallbackReason: fallbackReason)
    }

    private func resolveLatestBundled(fallbackReason: PassCLIResolutionFallback?) -> PassCLISelection {
        guard let bundled = discovery.latestBundledCandidate() else {
            return .unresolved(command: "pass-cli")
        }
        return .bundled(
            path: bundled.path,
            version: bundled.version.description,
            architecture: bundled.architecture,
            requested: .latest,
            fallbackReason: fallbackReason
        )
    }
}
