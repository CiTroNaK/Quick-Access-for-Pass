import Foundation
import os

nonisolated enum CLIError: Error, LocalizedError {
    case notInstalled
    case notLoggedIn
    case commandFailed(String)
    case timeout
    case parseError(String)

    var isNotInstalled: Bool {
        if case .notInstalled = self { return true }
        return false
    }

    var isAuthError: Bool {
        switch self {
        case .notLoggedIn: true
        case .commandFailed(let msg): CLIRunner.stderrIndicatesNotLoggedIn(msg)
        default: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .notInstalled: String(localized: "pass-cli is not installed. Instructionas at https://protonpass.github.io/pass-cli/")
        case .notLoggedIn: String(localized: "Not logged in to Proton Pass. Please run: pass-cli login")
        case .commandFailed(let msg): String(localized: "pass-cli command failed: \(msg)")
        case .timeout: String(localized: "pass-cli command timed out")
        case .parseError(let msg): String(localized: "Failed to parse pass-cli output: \(msg)")
        }
    }
}

nonisolated private struct PassCLIVersion: Comparable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    static func < (lhs: PassCLIVersion, rhs: PassCLIVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

actor PassCLIService {
    private static let minimumShowSecretsVersion = PassCLIVersion(major: 2, minor: 0, patch: 3)

    private nonisolated let selectionStore: OSAllocatedUnfairLock<PassCLISelection>
    private let resolver: PassCLIResolver
    private let timeoutSeconds: Double = 300
    private let runner: any CLIRunning
    private var supportsShowSecretsCache: (path: String, supported: Bool)?
    private var supportsShowSecretsTask: (path: String, task: Task<Bool, Never>)?

    nonisolated var cliSelection: PassCLISelection {
        selectionStore.withLock { $0 }
    }

    nonisolated var cliPath: String {
        cliSelection.path
    }

    @discardableResult
    nonisolated func updateCLISelection(customPath: String?) -> Bool {
        let resolved = resolver.resolve(customPath: customPath)
        return selectionStore.withLock { selection in
            guard selection != resolved else { return false }
            selection = resolved
            return true
        }
    }

    nonisolated func updateCLIPath(_ path: String) {
        selectionStore.withLock { $0 = .custom(path: path) }
    }

    init(
        cliPath: String? = nil,
        resolver: PassCLIResolver = PassCLIResolver(),
        runner: any CLIRunning = LiveCLIRunner()
    ) {
        let resolved = resolver.resolve(customPath: cliPath)
        self.selectionStore = OSAllocatedUnfairLock(initialState: resolved)
        self.resolver = resolver
        self.runner = runner
    }

    // MARK: - Commands

    func listVaults() async throws -> [CLIVault] {
        let data = try await run(arguments: ["vault", "list", "--output", "json"])
        return try Self.parseVaultList(from: data)
    }

    func listItems(shareId: String) async throws -> [CLIItem] {
        var arguments = ["item", "list", "--share-id=\(shareId)", "--output", "json"]
        if await supportsShowSecrets() {
            arguments.append("--show-secrets")
        }
        let data = try await run(arguments: arguments)
        return try Self.parseItemList(from: data)
    }

    func logout() async throws {
        _ = try await run(arguments: ["logout"])
    }

    func viewItem(itemId: String, shareId: String) async throws -> CLIItem {
        let uri = "pass://\(shareId)/\(itemId)"
        let data = try await run(arguments: ["item", "view", "--output", "json", uri])
        let response = try JSONDecoder().decode(CLIItemViewResponse.self, from: data)
        return response.item
    }

    func getTotp(itemId: String, shareId: String) async throws -> String {
        let uri = "pass://\(shareId)/\(itemId)"
        let data = try await run(arguments: ["item", "totp", "--output", "json", uri])
        return try Self.parseTotp(from: data)
    }

    func fetchAllItems() async throws -> (vaults: [CLIVault], items: [(item: CLIItem, vaultId: String)]) {
        let vaults = try await listVaults()
        let allItems = try await withThrowingTaskGroup(of: [(item: CLIItem, vaultId: String)].self) { group in
            for vault in vaults {
                group.addTask {
                    let items = try await self.listItems(shareId: vault.shareId)
                    return items.map { (item: $0, vaultId: vault.vaultId) }
                }
            }
            var result: [(item: CLIItem, vaultId: String)] = []
            for try await batch in group {
                result.append(contentsOf: batch)
            }
            return result
        }
        return (vaults, allItems)
    }

    // MARK: - CLI Capabilities

    private func supportsShowSecrets() async -> Bool {
        let executablePath = cliPath
        if let cache = supportsShowSecretsCache, cache.path == executablePath {
            return cache.supported
        }
        if let inFlight = supportsShowSecretsTask, inFlight.path == executablePath {
            return await inFlight.task.value
        }

        let runner = self.runner
        let timeoutSeconds = self.timeoutSeconds
        let task = Task<Bool, Never> {
            do {
                let data = try await runner.run(
                    executablePath: executablePath,
                    arguments: ["--version"],
                    timeout: timeoutSeconds
                )
                guard let output = String(bytes: data, encoding: .utf8) else {
                    return false
                }
                return Self.parseVersion(from: output).map { $0 >= Self.minimumShowSecretsVersion } ?? false
            } catch {
                return false
            }
        }
        supportsShowSecretsTask = (path: executablePath, task: task)

        let supported = await task.value
        if cliPath == executablePath {
            supportsShowSecretsCache = (path: executablePath, supported: supported)
        }
        if supportsShowSecretsTask?.path == executablePath {
            supportsShowSecretsTask = nil
        }
        return supported
    }

    private static func parseVersion(from output: String) -> PassCLIVersion? {
        guard let range = output.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else {
            return nil
        }
        let components = output[range].split(separator: ".").compactMap { Int($0) }
        guard components.count == 3 else { return nil }
        return PassCLIVersion(major: components[0], minor: components[1], patch: components[2])
    }

    // MARK: - Process Execution

    private func run(arguments: [String]) async throws -> Data {
        try await runner.run(executablePath: cliPath, arguments: arguments, timeout: timeoutSeconds)
    }

    // MARK: - Parsing (static for testing)

    static func parseVaultList(from data: Data) throws -> [CLIVault] {
        do {
            return try JSONDecoder().decode(CLIVaultListResponse.self, from: data).vaults
        } catch {
            throw CLIError.parseError(parseErrorDescription(error, context: "vault list"))
        }
    }

    static func parseItemList(from data: Data) throws -> [CLIItem] {
        do {
            return try JSONDecoder().decode(CLIItemListResponse.self, from: data).items
        } catch {
            throw CLIError.parseError(parseErrorDescription(error, context: "item list"))
        }
    }

    static func parseTotp(from data: Data) throws -> String {
        do {
            return try JSONDecoder().decode(CLITotpResponse.self, from: data).totp
        } catch {
            throw CLIError.parseError(parseErrorDescription(error, context: "item totp"))
        }
    }

    private static func parseErrorDescription(_ error: Error, context: String) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, let decodingContext):
            let path = codingPathDescription(decodingContext.codingPath + [key])
            return "\(context): missing '\(key.stringValue)' at \(path)"
        case DecodingError.valueNotFound(let type, let decodingContext):
            return "\(context): missing \(type) value at \(codingPathDescription(decodingContext.codingPath))"
        case DecodingError.typeMismatch(let type, let decodingContext):
            return "\(context): expected \(type) at \(codingPathDescription(decodingContext.codingPath))"
        case DecodingError.dataCorrupted(let decodingContext):
            return "\(context): corrupted data at \(codingPathDescription(decodingContext.codingPath)): \(decodingContext.debugDescription)"
        default:
            return "\(context): \(error.localizedDescription)"
        }
    }

    private static func codingPathDescription(_ path: [CodingKey]) -> String {
        guard !path.isEmpty else { return "<root>" }
        return path.map(\.stringValue).joined(separator: ".")
    }
}
