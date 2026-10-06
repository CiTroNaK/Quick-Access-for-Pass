import Foundation

/// Async closure retained only for focused ordinary-action tests.
typealias CLIItemFetcher = @Sendable (_ itemId: String, _ shareId: String) async throws -> CLIItem

nonisolated protocol SecretItemResolving: Sendable {
    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> CLIItem
    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> String
}

extension SecretItemResolving {
    func resolveItem(itemId: String, vaultId: String, shareId: String) async throws -> CLIItem {
        try await resolveItem(itemId: itemId, vaultId: vaultId, shareId: shareId, context: .ordinary)
    }

    func resolveTOTP(itemId: String, vaultId: String, shareId: String) async throws -> String {
        try await resolveTOTP(itemId: itemId, vaultId: vaultId, shareId: shareId, context: .ordinary)
    }
}

nonisolated protocol OfflineSecretResolvingLive: Sendable {
    func viewItem(itemId: String, shareId: String) async throws -> CLIItem
    func getTotp(itemId: String, shareId: String) async throws -> String
    func viewItem(itemId: String, shareId: String, timeout: TimeInterval) async throws -> CLIItem
    func getTotp(itemId: String, shareId: String, timeout: TimeInterval) async throws -> String
}

extension PassCLIService: OfflineSecretResolvingLive {}

/// Live-only resolver used when offline mode has not been composed at a call site.
nonisolated struct LiveSecretItemResolver: SecretItemResolving {
    let cliService: PassCLIService

    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> CLIItem {
        if let timeout = try OfflineAutoFillLiveBudget.timeout(context: context, hasSnapshot: false) {
            return try await cliService.viewItem(itemId: itemId, shareId: shareId, timeout: timeout)
        }
        return try await cliService.viewItem(itemId: itemId, shareId: shareId)
    }

    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> String {
        if let timeout = try OfflineAutoFillLiveBudget.timeout(context: context, hasSnapshot: false) {
            return try await cliService.getTotp(itemId: itemId, shareId: shareId, timeout: timeout)
        }
        return try await cliService.getTotp(itemId: itemId, shareId: shareId)
    }
}

/// Compatibility adapter for existing focused ordinary-action tests. It cannot
/// serve a broker deadline because a closure cannot enforce native cancellation.
nonisolated struct LegacySecretItemResolver: SecretItemResolving {
    let fetchItem: CLIItemFetcher
    let cliService: PassCLIService

    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> CLIItem {
        guard context.deadlineUptimeNanoseconds == nil else { throw SecretResolutionError.deadlineExpired }
        return try await fetchItem(itemId, shareId)
    }

    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> String {
        guard context.deadlineUptimeNanoseconds == nil else { throw SecretResolutionError.deadlineExpired }
        return try await cliService.getTotp(itemId: itemId, shareId: shareId)
    }
}

/// Resolves live values first, then conditionally decrypts a repository-authorized snapshot.
actor OfflineSecretResolver: SecretItemResolving {
    enum Error: Swift.Error, LocalizedError, Equatable, Sendable {
        case unavailable

        var errorDescription: String? {
            String(localized: "Not available offline. Sign in to Proton Pass or reconnect, then try again.")
        }
    }

    private let live: any OfflineSecretResolvingLive
    private let repository: any OfflineSnapshotPersisting
    private let codec: any OfflineSnapshotCoding
    private let readiness: any OfflineInitializationProviding
    private let now: @Sendable () -> UInt64

    init(
        live: any OfflineSecretResolvingLive,
        repository: any OfflineSnapshotPersisting,
        codec: any OfflineSnapshotCoding,
        readiness: any OfflineInitializationProviding,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.live = live
        self.repository = repository
        self.codec = codec
        self.readiness = readiness
        self.now = now
    }

    init(
        cliService: PassCLIService,
        repository: any OfflineSnapshotPersisting,
        codec: any OfflineSnapshotCoding,
        readiness: any OfflineInitializationProviding
    ) {
        self.init(live: cliService, repository: repository, codec: codec, readiness: readiness)
    }

    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> CLIItem {
        let key = OfflineSnapshotKey(vaultId: vaultId, itemId: itemId, schemaVersion: OfflineSnapshotLimits.schemaVersion)
        let hasSnapshot = try await usableSnapshotExists(for: key)
        let timeout = try OfflineAutoFillLiveBudget.timeout(context: context, hasSnapshot: hasSnapshot, now: now())
        do {
            let item: CLIItem
            if let timeout { item = try await live.viewItem(itemId: itemId, shareId: shareId, timeout: timeout) }
            else { item = try await live.viewItem(itemId: itemId, shareId: shareId) }
            try checkDeadline(context)
            return item
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try checkDeadline(context)
            guard hasSnapshot, eligibleFallback(error) else { throw error }
            return try await cachedItem(itemId: itemId, vaultId: vaultId, context: context)
        }
    }

    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> String {
        let key = OfflineSnapshotKey(vaultId: vaultId, itemId: itemId, schemaVersion: OfflineSnapshotLimits.schemaVersion)
        let hasSnapshot = try await usableSnapshotExists(for: key)
        let timeout = try OfflineAutoFillLiveBudget.timeout(context: context, hasSnapshot: hasSnapshot, now: now())
        do {
            let code: String
            if let timeout { code = try await live.getTotp(itemId: itemId, shareId: shareId, timeout: timeout) }
            else { code = try await live.getTotp(itemId: itemId, shareId: shareId) }
            try checkDeadline(context)
            return code
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try checkDeadline(context)
            guard hasSnapshot, eligibleFallback(error) else { throw error }
            let item = try await cachedItem(itemId: itemId, vaultId: vaultId, context: context)
            guard case .login(let login) = item.content.content, !login.totpUri.isEmpty else { throw Error.unavailable }
            let code = try TOTPGenerator.code(from: login.totpUri)
            try checkDeadline(context)
            return code
        }
    }

    private func usableSnapshotExists(for key: OfflineSnapshotKey) async throws -> Bool {
        guard await readiness.isReady() else { return false }
        return try await repository.hasAuthorizedSnapshot(for: key)
    }

    private func cachedItem(itemId: String, vaultId: String, context: SecretResolutionContext) async throws -> CLIItem {
        try Task.checkCancellation()
        try checkDeadline(context)
        guard await readiness.isReady() else { throw Error.unavailable }
        let key = OfflineSnapshotKey(vaultId: vaultId, itemId: itemId, schemaVersion: OfflineSnapshotLimits.schemaVersion)
        for attempt in 0...1 {
            guard let snapshot = try await repository.authorizedSnapshot(for: key) else { throw Error.unavailable }
            do {
                let item = try await codec.decodeSnapshot(snapshot)
                try Task.checkCancellation()
                try checkDeadline(context)
                try validateCachedUsername(item, context: context)
                guard try await repository.isAuthorized(snapshot) else {
                    if attempt == 0 { continue }
                    throw Error.unavailable
                }
                return item
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as OfflineSnapshotCodec.Error {
                if shouldDiscard(error) { try? await repository.discardCorruptSnapshot(snapshot) }
                if attempt == 0, try await repository.hasAuthorizedSnapshot(for: key) { continue }
                throw Error.unavailable
            } catch let error as AutoFillSecretResolverError {
                // Identity mismatch is an authorization failure, not a cache
                // decoder failure. The broker maps it to generic IPC failure.
                throw error
            } catch {
                // Decoder and cache failures are intentionally classified at
                // this boundary; payload/error dictionaries never reach UI or logs.
                throw Error.unavailable
            }
        }
        throw Error.unavailable
    }

    private func checkDeadline(_ context: SecretResolutionContext) throws {
        guard let deadline = context.deadlineUptimeNanoseconds else { return }
        guard deadline > now() else { throw SecretResolutionError.deadlineExpired }
    }

    /// Every decoded cached release independently verifies the broker's login
    /// identity, including a replacement snapshot reached by the retry loop.
    private func validateCachedUsername(_ item: CLIItem, context: SecretResolutionContext) throws {
        guard context.expectedUsername != nil else { return }
        guard case .login(let login) = item.content.content else { throw Error.unavailable }
        try validateAutoFillUsername(login, expectedUsername: context.expectedUsername)
    }

    private nonisolated func shouldDiscard(_ error: OfflineSnapshotCodec.Error) -> Bool {
        switch error {
        case .corruptSnapshot, .invalidIdentity: true
        case .keyUnavailable, .payloadTooLarge, .unsupportedSchemaVersion: false
        }
    }

    private nonisolated func eligibleFallback(_ error: Swift.Error) -> Bool {
        switch error {
        case CLIError.notInstalled, CLIError.notLoggedIn, CLIError.timeout: true
        default: false
        }
    }
}
