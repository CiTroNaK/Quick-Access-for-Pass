import Foundation

/// Async closure retained only for focused ordinary-action tests.
typealias CLIItemFetcher = @Sendable (_ itemId: String, _ shareId: String) async throws -> CLIItem

nonisolated protocol SecretItemResolving: Sendable {
    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<CLIItem>
    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<String>
    func resolveAutoFillValue(itemId: String, vaultId: String, shareId: String, kind: AutoFillValueKind, context: SecretResolutionContext) async throws -> ResolvedSecret<String>
}

extension SecretItemResolving {
    func resolveItem(itemId: String, vaultId: String, shareId: String) async throws -> ResolvedSecret<CLIItem> {
        try await resolveItem(itemId: itemId, vaultId: vaultId, shareId: shareId, context: .ordinary)
    }

    func resolveTOTP(itemId: String, vaultId: String, shareId: String) async throws -> ResolvedSecret<String> {
        try await resolveTOTP(itemId: itemId, vaultId: vaultId, shareId: shareId, context: .ordinary)
    }
}

nonisolated protocol OfflineSecretResolvingLive: Sendable {
    func viewItem(itemId: String, shareId: String) async throws -> CLIItem
    func getTotp(itemId: String, shareId: String) async throws -> String
    func viewItem(itemId: String, shareId: String, timeout: TimeInterval) async throws -> CLIItem
    func getTotp(itemId: String, shareId: String, timeout: TimeInterval) async throws -> String
    func viewItem(itemId: String, shareId: String, deadline: CLIExecutionDeadline) async throws -> CLIItem
    func getTotp(itemId: String, shareId: String, deadline: CLIExecutionDeadline) async throws -> String
}

extension OfflineSecretResolvingLive {
    func viewItem(itemId: String, shareId: String, deadline: CLIExecutionDeadline) async throws -> CLIItem {
        try await viewItem(itemId: itemId, shareId: shareId, timeout: deadline.remainingSeconds(at: DispatchTime.now().uptimeNanoseconds))
    }
    func getTotp(itemId: String, shareId: String, deadline: CLIExecutionDeadline) async throws -> String {
        try await getTotp(itemId: itemId, shareId: shareId, timeout: deadline.remainingSeconds(at: DispatchTime.now().uptimeNanoseconds))
    }
}

extension PassCLIService: OfflineSecretResolvingLive {}

/// Live-only resolver used when offline mode has not been composed at a call site.
nonisolated struct LiveSecretItemResolver: SecretItemResolving {
    let cliService: PassCLIService

    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<CLIItem> {
        if let deadline = try OfflineAutoFillLiveBudget.deadline(context: context, hasSnapshot: false, now: DispatchTime.now().uptimeNanoseconds) {
            return ResolvedSecret(value: try await cliService.viewItem(itemId: itemId, shareId: shareId, deadline: deadline), offlineCapability: nil)
        }
        return ResolvedSecret(value: try await cliService.viewItem(itemId: itemId, shareId: shareId), offlineCapability: nil)
    }

    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<String> {
        if let deadline = try OfflineAutoFillLiveBudget.deadline(context: context, hasSnapshot: false, now: DispatchTime.now().uptimeNanoseconds) {
            return ResolvedSecret(value: try await cliService.getTotp(itemId: itemId, shareId: shareId, deadline: deadline), offlineCapability: nil)
        }
        return ResolvedSecret(value: try await cliService.getTotp(itemId: itemId, shareId: shareId), offlineCapability: nil)
    }

    func resolveAutoFillValue(itemId: String, vaultId: String, shareId: String, kind: AutoFillValueKind, context: SecretResolutionContext) async throws -> ResolvedSecret<String> {
        try await PassCLIAutoFillSecretResolver(cliService: cliService).resolveLiveValue(
            itemId: itemId, shareId: shareId, kind: kind, context: context
        )
    }
}

/// Compatibility adapter for existing focused ordinary-action tests. It cannot
/// serve a broker deadline because a closure cannot enforce native cancellation.
nonisolated struct LegacySecretItemResolver: SecretItemResolving {
    let fetchItem: CLIItemFetcher
    let cliService: PassCLIService

    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<CLIItem> {
        guard context.deadlineUptimeNanoseconds == nil else { throw SecretResolutionError.deadlineExpired }
        return ResolvedSecret(value: try await fetchItem(itemId, shareId), offlineCapability: nil)
    }

    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<String> {
        guard context.deadlineUptimeNanoseconds == nil else { throw SecretResolutionError.deadlineExpired }
        return ResolvedSecret(value: try await cliService.getTotp(itemId: itemId, shareId: shareId), offlineCapability: nil)
    }

    func resolveAutoFillValue(itemId: String, vaultId: String, shareId: String, kind: AutoFillValueKind, context: SecretResolutionContext) async throws -> ResolvedSecret<String> {
        throw AutoFillSecretResolverError.unsupportedResolver
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
    private let releaseAuthority: OfflineReleaseAuthority
    private let codec: any OfflineSnapshotCoding
    private let readiness: any OfflineInitializationProviding
    private let now: @Sendable () -> UInt64
    private let totpDate: @Sendable () -> Date

    init(
        live: any OfflineSecretResolvingLive,
        repository: any OfflineSnapshotPersisting,
        codec: any OfflineSnapshotCoding,
        readiness: any OfflineInitializationProviding,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        totpDate: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.live = live
        self.repository = repository
        self.releaseAuthority = repository.releaseAuthority
        self.codec = codec
        self.readiness = readiness
        self.now = now
        self.totpDate = totpDate
    }

    init(
        cliService: PassCLIService,
        repository: any OfflineSnapshotPersisting,
        codec: any OfflineSnapshotCoding,
        readiness: any OfflineInitializationProviding
    ) {
        self.init(live: cliService, repository: repository, codec: codec, readiness: readiness)
    }

    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<CLIItem> {
        let key = OfflineSnapshotKey(vaultId: vaultId, itemId: itemId, schemaVersion: OfflineSnapshotLimits.schemaVersion)
        let hasSnapshot = try await usableSnapshotExists(for: key)
        let phaseDeadline = try OfflineAutoFillLiveBudget.deadline(context: context, hasSnapshot: hasSnapshot, now: now())
        do {
            let item: CLIItem
            if let phaseDeadline {
                item = try await live.viewItem(itemId: itemId, shareId: shareId, deadline: phaseDeadline)
            } else { item = try await live.viewItem(itemId: itemId, shareId: shareId) }
            try checkDeadline(context)
            return ResolvedSecret(value: item, offlineCapability: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try checkDeadline(context)
            guard hasSnapshot, eligibleFallback(error) else { throw error }
            return try await cachedItem(itemId: itemId, vaultId: vaultId, context: context)
        }
    }

    func resolveAutoFillValue(itemId: String, vaultId: String, shareId: String, kind: AutoFillValueKind, context: SecretResolutionContext) async throws -> ResolvedSecret<String> {
        try Task.checkCancellation()
        let key = OfflineSnapshotKey(vaultId: vaultId, itemId: itemId, schemaVersion: OfflineSnapshotLimits.schemaVersion)
        let hasSnapshot = try await usableSnapshotExists(for: key)
        let phaseDeadline = try OfflineAutoFillLiveBudget.deadline(context: context, hasSnapshot: hasSnapshot, now: now())
        try Task.checkCancellation()
        let item: CLIItem
        do {
            if let phaseDeadline { item = try await live.viewItem(itemId: itemId, shareId: shareId, deadline: phaseDeadline) }
            else { item = try await live.viewItem(itemId: itemId, shareId: shareId) }
            try Task.checkCancellation()
            try checkDeadline(context)
            if let phaseDeadline, now() >= phaseDeadline.uptimeNanoseconds { throw CLIError.timeout }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            try checkOriginalDeadline(context)
            guard hasSnapshot, eligibleFallback(error) else { throw error }
            let cached = try await cachedItem(itemId: itemId, vaultId: vaultId, context: context)
            return try cached.map { item in try autoFillValue(item, kind: kind, context: context) }
        }
        guard case .login(let login) = item.content.content else { throw AutoFillSecretResolverError.itemIsNotLogin }
        try validateAutoFillUsername(login, expectedUsername: context.expectedUsername)
        switch kind {
        case .password:
            try Task.checkCancellation()
            try checkDeadline(context)
            return ResolvedSecret(value: login.password, offlineCapability: nil)
        case .oneTimeCode:
            guard !login.totpUri.isEmpty else { throw AutoFillSecretResolverError.descriptorDoesNotSupportValue }
            do {
                if let phaseDeadline, now() >= phaseDeadline.uptimeNanoseconds {
                    throw CLIError.timeout
                }
                let value: String
                if let phaseDeadline { value = try await live.getTotp(itemId: itemId, shareId: shareId, deadline: phaseDeadline) }
                else { value = try await live.getTotp(itemId: itemId, shareId: shareId) }
                try Task.checkCancellation()
                try checkDeadline(context)
                if let phaseDeadline, now() >= phaseDeadline.uptimeNanoseconds { throw CLIError.timeout }
                return ResolvedSecret(value: value, offlineCapability: nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                try checkOriginalDeadline(context)
                guard hasSnapshot, eligibleFallback(error) else { throw error }
                let cached = try await cachedItem(itemId: itemId, vaultId: vaultId, context: context)
                return try cached.map { item in try autoFillValue(item, kind: kind, context: context) }
            }
        }
    }

    private func autoFillValue(_ item: CLIItem, kind: AutoFillValueKind, context: SecretResolutionContext) throws -> String {
        guard case .login(let login) = item.content.content else { throw AutoFillSecretResolverError.itemIsNotLogin }
        try validateAutoFillUsername(login, expectedUsername: context.expectedUsername)
        switch kind {
        case .password: return login.password
        case .oneTimeCode:
            guard !login.totpUri.isEmpty else { throw AutoFillSecretResolverError.descriptorDoesNotSupportValue }
            return try TOTPGenerator.code(from: login.totpUri, at: totpDate())
        }
    }

    private func checkOriginalDeadline(_ context: SecretResolutionContext) throws {
        guard let deadline = context.deadlineUptimeNanoseconds else { return }
        guard deadline > now() else { throw SecretResolutionError.deadlineExpired }
    }

    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<String> {
        let key = OfflineSnapshotKey(vaultId: vaultId, itemId: itemId, schemaVersion: OfflineSnapshotLimits.schemaVersion)
        let hasSnapshot = try await usableSnapshotExists(for: key)
        let phaseDeadline = try OfflineAutoFillLiveBudget.deadline(context: context, hasSnapshot: hasSnapshot, now: now())
        do {
            let code: String
            if let phaseDeadline {
                code = try await live.getTotp(itemId: itemId, shareId: shareId, deadline: phaseDeadline)
            } else { code = try await live.getTotp(itemId: itemId, shareId: shareId) }
            try checkDeadline(context)
            return ResolvedSecret(value: code, offlineCapability: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try checkDeadline(context)
            guard hasSnapshot, eligibleFallback(error) else { throw error }
            let item = try await cachedItem(itemId: itemId, vaultId: vaultId, context: context)
            let code = try item.map { item in
                guard case .login(let login) = item.content.content, !login.totpUri.isEmpty else { throw Error.unavailable }
                return try TOTPGenerator.code(from: login.totpUri, at: totpDate())
            }
            try checkDeadline(context)
            return code
        }
    }

    private func usableSnapshotExists(for key: OfflineSnapshotKey) async throws -> Bool {
        try Task.checkCancellation()
        guard await readiness.isReady() else {
            try Task.checkCancellation()
            return false
        }
        try Task.checkCancellation()
        do {
            return try await repository.hasAuthorizedSnapshot(for: key)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return false
        }
    }

    private func cachedItem(itemId: String, vaultId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<CLIItem> {
        try Task.checkCancellation()
        try checkDeadline(context)
        guard await readiness.isReady() else { throw Error.unavailable }
        let key = OfflineSnapshotKey(vaultId: vaultId, itemId: itemId, schemaVersion: OfflineSnapshotLimits.schemaVersion)
        for attempt in 0...1 {
            let capture = releaseAuthority.capture(for: key)
            guard let snapshot = try await repository.authorizedSnapshot(for: key) else {
                if attempt == 0 { continue }
                throw Error.unavailable
            }
            do {
                guard let initialProof = try await repository.releaseProof(for: snapshot) else {
                    if attempt == 0 { continue }
                    throw Error.unavailable
                }
                try releaseAuthority.bind(capture, proof: initialProof)
                let item = try await codec.decodeSnapshot(snapshot)
                try Task.checkCancellation()
                try checkDeadline(context)
                try validateCachedUsername(item, context: context)
                guard item.content.content.itemType == initialProof.itemType,
                      let proof = try await repository.releaseProof(for: snapshot) else {
                    if attempt == 0 { continue }
                    throw Error.unavailable
                }
                let capability = try releaseAuthority.authorize(capture, proof: proof)
                try Task.checkCancellation()
                try checkDeadline(context)
                return ResolvedSecret(value: item, offlineCapability: capability)
            } catch is OfflineReleaseError {
                if attempt == 0 { continue }
                throw Error.unavailable
            } catch is CancellationError {
                throw CancellationError()
            } catch SecretResolutionError.deadlineExpired {
                throw SecretResolutionError.deadlineExpired
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
