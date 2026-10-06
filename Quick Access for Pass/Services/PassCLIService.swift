import Foundation
import os

typealias SyncProgressHandler = @Sendable (SyncProgressPresentation) async -> Void

actor PassCLIService {
    private nonisolated let selectionStore: OSAllocatedUnfairLock<PassCLISelection>
    private let resolver: PassCLIResolver
    private let timeoutSeconds: Double = 300
    private static let secretOutputLimit = (4 * 1024 * 1024) + (4 * 1024)
    private let runner: any CLIRunning
    private var supportsShowSecretsCache: (path: String, supported: Bool)?
    private var supportsShowSecretsTask: (path: String, task: Task<Bool, Never>)?

    nonisolated var cliSelection: PassCLISelection {
        selectionStore.withLock { $0 }
    }

    nonisolated var cliPath: String {
        cliSelection.path
    }

    nonisolated var latestBundledVersion: PassCLIVersion? {
        resolver.latestBundledVersion
    }

    @discardableResult
    nonisolated func updateCLISelection(preference: PassCLISelectionPreference, customPath: String?) -> Bool {
        let resolved = resolver.resolve(preference: preference, customPath: customPath)
        return selectionStore.withLock { selection in
            guard selection != resolved else { return false }
            selection = resolved
            return true
        }
    }

    @discardableResult
    nonisolated func updateCLISelection(customPath: String?) -> Bool {
        let preference: PassCLISelectionPreference = {
            let path = customPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return path.isEmpty ? .auto : .custom
        }()
        return updateCLISelection(preference: preference, customPath: customPath)
    }

    nonisolated func updateCLIPath(_ path: String) {
        selectionStore.withLock { $0 = .custom(path: path) }
    }

    init(
        cliPath: String? = nil,
        preference: PassCLISelectionPreference? = nil,
        customPath: String? = nil,
        resolver: PassCLIResolver = PassCLIResolver(),
        runner: any CLIRunning = LiveCLIRunner()
    ) {
        let resolvedPreference = preference ?? {
            let path = cliPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return path.isEmpty ? .auto : .custom
        }()
        let resolvedCustomPath = customPath ?? cliPath
        let resolved = resolver.resolve(preference: resolvedPreference, customPath: resolvedCustomPath)
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

    func listItemsForSync(vault: CLIVault, progress: SyncProgressHandler? = nil) async throws -> CLIItemListParseResult {
        await progress?(.vaultStarted(vaultName: vault.name))
        var arguments = ["item", "list", "--share-id=\(vault.shareId)", "--filter-state=active", "--output", "json"]
        if await supportsShowSecrets() {
            arguments.append("--show-secrets")
        }
        let data = try await run(arguments: arguments)
        let result = try CLIItemListLossyParser.parse(
            data,
            vaultId: vault.vaultId,
            vaultName: vault.name,
            shareId: vault.shareId
        )
        await progress?(.itemsDecoded(
            vaultName: vault.name,
            completedItems: result.items.count,
            totalItems: result.totalItemCount,
            skippedItems: result.skippedItems.count
        ))
        return result
    }

    func logout() async throws {
        _ = try await run(arguments: ["logout"])
    }

    func viewItem(itemId: String, shareId: String) async throws -> CLIItem {
        try await viewItem(itemId: itemId, shareId: shareId, timeout: timeoutSeconds)
    }

    /// Secret reads always use the bounded runner, including ordinary actions.
    func viewItem(itemId: String, shareId: String, timeout: TimeInterval) async throws -> CLIItem {
        let uri = "pass://\(shareId)/\(itemId)"
        let data = try await runSecret(arguments: ["item", "view", "--output", "json", uri], timeout: timeout)
        do {
            return try JSONDecoder().decode(CLIItemViewResponse.self, from: data).item
        } catch {
            throw CLIError.secretFetchFailed
        }
    }

    func getTotp(itemId: String, shareId: String) async throws -> String {
        try await getTotp(itemId: itemId, shareId: shareId, timeout: timeoutSeconds)
    }

    /// Secret reads always use the bounded runner, including ordinary actions.
    func getTotp(itemId: String, shareId: String, timeout: TimeInterval) async throws -> String {
        let uri = "pass://\(shareId)/\(itemId)"
        let data = try await runSecret(arguments: ["item", "totp", "--output", "json", uri], timeout: timeout)
        do {
            return try JSONDecoder().decode(CLITotpResponse.self, from: data).totp
        } catch {
            throw CLIError.secretFetchFailed
        }
    }

    func fetchAllItems(
        progress: SyncProgressHandler? = nil
    ) async throws -> (
        vaults: [CLIVault],
        items: [(item: CLIItem, vaultId: String)],
        skippedItems: [SkippedSyncItem],
        presenceUncertainties: [SyncItemPresenceUncertainty]
    ) {
        let vaults = try await listVaults()
        let syncResult = try await withThrowingTaskGroup(
            of: (items: [(item: CLIItem, vaultId: String)], skippedItems: [SkippedSyncItem], presenceUncertainty: SyncItemPresenceUncertainty).self
        ) { group in
            for vault in vaults {
                group.addTask {
                    let result = try await self.listItemsForSync(vault: vault, progress: progress)
                    return (
                        items: result.items.map { (item: $0, vaultId: vault.vaultId) },
                        skippedItems: result.skippedItems,
                        presenceUncertainty: result.presenceUncertainty
                    )
                }
            }
            var items: [(item: CLIItem, vaultId: String)] = []
            var skippedItems: [SkippedSyncItem] = []
            var presenceUncertainties: [SyncItemPresenceUncertainty] = []
            for try await batch in group {
                items.append(contentsOf: batch.items)
                skippedItems.append(contentsOf: batch.skippedItems)
                presenceUncertainties.append(batch.presenceUncertainty)
            }
            return (items: items, skippedItems: skippedItems, presenceUncertainties: presenceUncertainties)
        }
        return (vaults, syncResult.items, syncResult.skippedItems, syncResult.presenceUncertainties)
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
                let output = String(bytes: data, encoding: .utf8)
                return PassCLICapabilities(rawVersionString: output).supportsShowSecrets
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

    // MARK: - Process Execution

    private func run(arguments: [String]) async throws -> Data {
        try await runner.run(executablePath: cliPath, arguments: arguments, timeout: timeoutSeconds)
    }

    private func runSecret(arguments: [String], timeout: TimeInterval) async throws -> Data {
        do {
            return try await runner.run(
                executablePath: cliPath,
                arguments: arguments,
                timeout: timeout,
                maximumOutputBytes: Self.secretOutputLimit
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CLIError {
            switch error {
            case .notInstalled, .notLoggedIn, .timeout, .outputLimitExceeded:
                throw error
            case .commandFailed, .secretFetchFailed, .parseError:
                throw CLIError.secretFetchFailed
            }
        } catch {
            throw CLIError.secretFetchFailed
        }
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

    static func parseErrorDescription(_ error: Error, context: String) -> String {
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

    static func codingPathDescription(_ path: [CodingKey]) -> String {
        guard !path.isEmpty else { return "<root>" }
        return path.map(\.stringValue).joined(separator: ".")
    }
}
