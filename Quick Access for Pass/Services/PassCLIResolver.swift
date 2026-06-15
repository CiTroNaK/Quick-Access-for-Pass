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

nonisolated enum PassCLISelection: Sendable, Equatable {
    case custom(path: String)
    case system(path: String)
    case bundled(path: String, architecture: PassCLIArchitecture)
    case unresolved(command: String)

    var path: String {
        switch self {
        case .custom(let path), .system(let path), .bundled(let path, _):
            path
        case .unresolved(let command):
            command
        }
    }

    var sourceLabel: String {
        switch self {
        case .custom(let path):
            "Custom: \(path)"
        case .system(let path):
            "System: \(path)"
        case .bundled(_, let architecture):
            "Bundled: pass-cli (\(architecture.rawValue))"
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
    private let which: any WhichResolving
    private let bundleURL: URL
    private let architecture: PassCLIArchitecture

    init(
        fileSystem: any ExecutableFileChecking = LiveExecutableFileSystem(),
        which: any WhichResolving = LiveWhichResolver(),
        bundleURL: URL = Bundle.main.bundleURL,
        architecture: PassCLIArchitecture = .current
    ) {
        self.fileSystem = fileSystem
        self.which = which
        self.bundleURL = bundleURL
        self.architecture = architecture
    }

    func resolve(customPath: String?) -> PassCLISelection {
        if let customPath = customPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !customPath.isEmpty {
            return .custom(path: customPath)
        }

        for path in systemCandidates where fileSystem.isExecutableFile(atPath: path) {
            return .system(path: path)
        }

        if let path = which.find("pass-cli"), fileSystem.isExecutableFile(atPath: path) {
            return .system(path: path)
        }

        let bundledPath = bundledHelperPath(for: architecture)
        if fileSystem.isExecutableFile(atPath: bundledPath) {
            return .bundled(path: bundledPath, architecture: architecture)
        }

        return .unresolved(command: "pass-cli")
    }

    private var systemCandidates: [String] {
        [
            "/opt/homebrew/bin/pass-cli",
            "/usr/local/bin/pass-cli",
            NSString(string: "~/.local/bin/pass-cli").expandingTildeInPath
        ]
    }

    private func bundledHelperPath(for architecture: PassCLIArchitecture) -> String {
        bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Helpers")
            .appendingPathComponent("pass-cli-\(architecture.rawValue)")
            .path
    }
}
