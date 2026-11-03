import Foundation
import os

typealias SyncProgressHandler = @Sendable (SyncProgressPresentation) async -> Void

actor PassCLIService {
    nonisolated let folderFeatureGate: FolderFeatureGate
    private let resolver: PassCLIResolver
    private let timeoutSeconds: Double = 300
    private static let secretOutputLimit = (4 * 1024 * 1024) + (4 * 1024)
    private static let versionProbeTimeoutSeconds: Double = 30
    private let runner: any CLIRunning
    private let executableFingerprint: @Sendable (String) -> PassCLIExecutableFingerprint?
    private var capabilitiesTask: (probe: FolderCapabilityProbe, task: Task<CapabilityProbeResult, Never>)?

    private struct CapabilityProbeResult {
        let capabilities: PassCLICapabilities
        /// False when the probe failed or timed out, so the result must not be reused.
        let isConclusive: Bool
    }

    nonisolated var cliSelection: PassCLISelection {
        folderFeatureGate.selection
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
        return folderFeatureGate.updateSelection(resolved)
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
        folderFeatureGate.updateSelection(.custom(path: path))
    }

    init(
        cliPath: String? = nil,
        preference: PassCLISelectionPreference? = nil,
        customPath: String? = nil,
        resolver: PassCLIResolver = PassCLIResolver(),
        runner: any CLIRunning = LiveCLIRunner(),
        executableFingerprint: @escaping @Sendable (String) -> PassCLIExecutableFingerprint? = {
            PassCLIExecutableFingerprint.live(path: $0)
        }
    ) {
        let resolvedPreference = preference ?? {
            let path = cliPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return path.isEmpty ? .auto : .custom
        }()
        let resolvedCustomPath = customPath ?? cliPath
        let resolved = resolver.resolve(preference: resolvedPreference, customPath: resolvedCustomPath)
        self.folderFeatureGate = FolderFeatureGate(selection: resolved)
        self.resolver = resolver
        self.runner = runner
        self.executableFingerprint = executableFingerprint
    }

    // MARK: - Commands

    func listVaults() async throws -> [CLIVault] {
        let data = try await run(arguments: ["vault", "list", "--output", "json"])
        return try Self.parseVaultList(from: data)
    }

    func listItems(shareId: String) async throws -> [CLIItem] {
        let selection = cliSelection
        var arguments = ["item", "list", "--share-id=\(shareId)", "--output", "json"]
        if await capabilities(for: selection).supportsShowSecrets {
            arguments.append("--show-secrets")
        }
        try Task.checkCancellation()
        let data = try await runner.run(executablePath: selection.path, arguments: arguments, timeout: timeoutSeconds)
        return try Self.parseItemList(from: data)
    }

    func listItemsForSync(vault: CLIVault, progress: SyncProgressHandler? = nil) async throws -> CLIItemListParseResult {
        try await listItemsForSync(vault: vault, selection: cliSelection, progress: progress)
    }

    private func listItemsForSync(
        vault: CLIVault, selection: PassCLISelection, progress: SyncProgressHandler?
    ) async throws -> CLIItemListParseResult {
        await progress?(.vaultStarted(vaultName: vault.name))
        let capabilities = await capabilities(for: selection)
        var arguments = ["item", "list", "--share-id=\(vault.shareId)", "--filter-state=active", "--output", "json"]
        if capabilities.supportsShowSecrets {
            arguments.append("--show-secrets")
        }
        try Task.checkCancellation()
        let data = try await runner.run(executablePath: selection.path, arguments: arguments, timeout: timeoutSeconds)
        let result = try CLIItemListLossyParser.parse(
            data,
            vaultId: vault.vaultId,
            vaultName: vault.name,
            shareId: vault.shareId,
            contentProvenance: capabilities.supportsShowSecrets ? capabilities.snapshotContentProvenance : .unavailable
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

    func viewItem(itemId: String, shareId: String, deadline: CLIExecutionDeadline) async throws -> CLIItem {
        let uri = "pass://\(shareId)/\(itemId)"
        let data = try await runSecret(arguments: ["item", "view", "--output", "json", uri], deadline: deadline)
        do { return try JSONDecoder().decode(CLIItemViewResponse.self, from: data).item } catch { throw CLIError.secretFetchFailed }
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

    func getTotp(itemId: String, shareId: String, deadline: CLIExecutionDeadline) async throws -> String {
        let uri = "pass://\(shareId)/\(itemId)"
        let data = try await runSecret(arguments: ["item", "totp", "--output", "json", uri], deadline: deadline)
        do { return try JSONDecoder().decode(CLITotpResponse.self, from: data).totp } catch { throw CLIError.secretFetchFailed }
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

    // MARK: - CLI Capabilities

    /// Establishes current capability before optional pre-fetch offline capture.
    /// Reprobes when the selection changed or its executable file changed in place (or cannot be
    /// inspected); otherwise keeps the confirmed probe so committed folder evidence stays current.
    func prepareFolderSync() async -> FolderFeatureStamp? {
        guard !Task.isCancelled else { return nil }
        let snapshot = folderFeatureGate.selectionSnapshot()
        let fingerprint = executableFingerprint(snapshot.selection.path)
        if case .reuse(let stamp) = folderFeatureGate.probeReuse(selectionGeneration: snapshot.generation,
                                                                  fingerprint: fingerprint) {
            return stamp
        }
        let probe = folderFeatureGate.beginProbe(fingerprint: fingerprint)
        _ = await probeCapabilities(probe)
        guard !Task.isCancelled,
              let stamp = folderFeatureGate.supportedStamp(),
              stamp.selectionGeneration == probe.selectionGeneration,
              stamp.probeRevision == probe.revision else { return nil }
        return stamp
    }

    private func capabilities(for selection: PassCLISelection) async -> PassCLICapabilities {
        let snapshot = folderFeatureGate.selectionSnapshot()
        guard snapshot.selection == selection else { return PassCLICapabilities(version: nil) }
        if let cached = folderFeatureGate.confirmedCapabilities(for: selection, generation: snapshot.generation) {
            return cached
        }
        if let inFlight = capabilitiesTask, inFlight.probe.selectionGeneration == snapshot.generation {
            return await inFlight.task.value.capabilities
        }
        let probe = folderFeatureGate.beginProbe(fingerprint: executableFingerprint(selection.path))
        guard probe.selection == selection, probe.selectionGeneration == snapshot.generation else {
            return PassCLICapabilities(version: nil)
        }
        return await probeCapabilities(probe)
    }

    private func probeCapabilities(_ probe: FolderCapabilityProbe) async -> PassCLICapabilities {
        let runner = self.runner
        let timeout = Self.versionProbeTimeoutSeconds
        // Version is metadata-only but must not delay ordinary sync for its 300-second content budget.
        // A cold first launch can be slow, so a failure stays inconclusive rather than "no version".
        let task = Task<CapabilityProbeResult, Never> {
            do {
                let data = try await runner.run(
                    executablePath: probe.selection.path, arguments: ["--version"], timeout: timeout
                )
                return CapabilityProbeResult(
                    capabilities: PassCLICapabilities(rawVersionString: String(bytes: data, encoding: .utf8)),
                    isConclusive: true
                )
            } catch {
                return CapabilityProbeResult(capabilities: PassCLICapabilities(version: nil), isConclusive: false)
            }
        }
        capabilitiesTask = (probe: probe, task: task)
        let value = await task.value
        folderFeatureGate.confirm(capabilities: value.capabilities, for: probe, cacheable: value.isConclusive)
        if capabilitiesTask?.probe == probe { capabilitiesTask = nil }
        return value.capabilities
    }

    // MARK: - Process Execution

    private func run(arguments: [String]) async throws -> Data {
        try await runner.run(executablePath: cliPath, arguments: arguments, timeout: timeoutSeconds)
    }

    private func runSecret(arguments: [String], deadline: CLIExecutionDeadline) async throws -> Data {
        do {
            return try await runner.run(
                executablePath: cliPath, arguments: arguments,
                deadline: deadline, maximumOutputBytes: Self.secretOutputLimit
            )
        } catch {
            throw Self.sanitizedSecretRunnerError(error)
        }
    }

    private func runSecret(arguments: [String], timeout: TimeInterval) async throws -> Data {
        do {
            return try await runner.run(
                executablePath: cliPath, arguments: arguments,
                timeout: timeout, maximumOutputBytes: Self.secretOutputLimit
            )
        } catch {
            throw Self.sanitizedSecretRunnerError(error)
        }
    }

    private static func sanitizedSecretRunnerError(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        guard let cliError = error as? CLIError else { return CLIError.secretFetchFailed }
        switch cliError {
        case .notInstalled, .notLoggedIn, .timeout, .outputLimitExceeded:
            return cliError
        case .commandFailed, .secretFetchFailed, .parseError:
            return CLIError.secretFetchFailed
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

extension PassCLIService {
    func fetchAllItems(
        folderFeatureStamp: FolderFeatureStamp? = nil,
        progress: SyncProgressHandler? = nil
    ) async throws -> CLISyncFetchResult {
        let selection = cliSelection
        let vaultData = try await runner.run(
            executablePath: selection.path, arguments: ["vault", "list", "--output", "json"], timeout: timeoutSeconds
        )
        let vaults = try Self.parseVaultList(from: vaultData)
        let syncResult = try await withThrowingTaskGroup(
            of: (vaultID: String, result: CLIItemListParseResult).self
        ) { group in
            for vault in vaults {
                group.addTask {
                    let result = try await self.listItemsForSync(vault: vault, selection: selection, progress: progress)
                    return (vaultID: vault.vaultId, result: result)
                }
            }
            var items: [(item: CLIItem, vaultId: String)] = []
            var skippedItems: [SkippedSyncItem] = []
            var presenceUncertainties: [SyncItemPresenceUncertainty] = []
            var provenance: [String: CLISnapshotContentProvenance] = [:]
            var memberships: [String: [String: CLIFolderMembership]] = [:]
            for try await batch in group {
                items.append(contentsOf: batch.result.items.map { (item: $0, vaultId: batch.vaultID) })
                skippedItems.append(contentsOf: batch.result.skippedItems)
                presenceUncertainties.append(batch.result.presenceUncertainty)
                provenance[batch.vaultID] = batch.result.contentProvenance
                memberships[batch.vaultID] = batch.result.folderMembershipEvidence
            }
            return (items: items, skippedItems: skippedItems, presenceUncertainties: presenceUncertainties,
                    provenance: provenance, memberships: memberships)
        }
        // Separate metadata-only commands are sequential, adding no unbounded vault fan-out.
        var folderCatalogs: [String: FolderCatalogFetchOutcome] = [:]
        for vault in vaults {
            try Task.checkCancellation()
            folderCatalogs[vault.vaultId] = await fetchFolderCatalog(
                vault: vault, memberships: syncResult.memberships[vault.vaultId],
                selection: selection, stamp: folderFeatureStamp
            )
        }
        try Task.checkCancellation()
        return CLISyncFetchResult(
            vaults: vaults, items: syncResult.items, skippedItems: syncResult.skippedItems,
            presenceUncertainties: syncResult.presenceUncertainties,
            contentProvenanceByVaultID: syncResult.provenance,
            folderCatalogsByVaultID: folderCatalogs
        )
    }

    /// Narrow metadata runner access for the folder extension; no actor internals exposed.
    func folderListData(shareID: String, selection: PassCLISelection, stamp: FolderFeatureStamp) async throws -> Data {
        guard folderFeatureGate.isCurrent(stamp), cliSelection == selection else { throw FolderCatalogError.incompleteEvidence }
        try Task.checkCancellation()
        return try await runner.run(
            executablePath: selection.path,
            arguments: ["folder", "list", "--share-id=\(shareID)", "--output", "json"],
            timeout: timeoutSeconds, maximumOutputBytes: FolderCatalogLimits.maximumOutputBytes
        )
    }
}
