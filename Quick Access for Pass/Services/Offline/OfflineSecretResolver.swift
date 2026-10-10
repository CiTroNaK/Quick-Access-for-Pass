import Foundation

/// Async closure retained only for focused ordinary-action tests.
typealias CLIItemFetcher = @Sendable (_ itemId: String, _ shareId: String) async throws -> CLIItem

nonisolated protocol SecretItemResolving: Sendable {
    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<CLIItem>
    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<String>
    func resolveAutoFillValue(
        itemId: String, vaultId: String, shareId: String, kind: AutoFillValueKind, context: SecretResolutionContext
    ) async throws -> ResolvedSecret<String>
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

/// Prefers repository-authorized snapshots; live access is used only without a usable copy.
actor OfflineSecretResolver: SecretItemResolving {
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

    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<CLIItem> {
        let lookup = try await preferredCachedItem(itemId: itemId, vaultId: vaultId, context: context)
        if let cached = lookup.item { return cached }
        let deadline = try liveDeadline(context)
        let item = try await liveItem(itemId: itemId, shareId: shareId, deadline: deadline, context: context, cacheUnavailable: lookup.cacheUnavailable)
        return ResolvedSecret(value: item, offlineCapability: nil)
    }

    func resolveAutoFillValue(
        itemId: String, vaultId: String, shareId: String, kind: AutoFillValueKind, context: SecretResolutionContext
    ) async throws -> ResolvedSecret<String> {
        let lookup = try await preferredCachedItem(itemId: itemId, vaultId: vaultId, context: context)
        if let cached = lookup.item {
            let result = try cached.map { try autoFillValue($0, kind: kind, context: context) }
            try checkRequest(context)
            return result
        }
        let deadline = try liveDeadline(context)
        let item = try await liveItem(itemId: itemId, shareId: shareId, deadline: deadline, context: context, cacheUnavailable: lookup.cacheUnavailable)
        guard case .login(let login) = item.content.content else { throw AutoFillSecretResolverError.itemIsNotLogin }
        try validateAutoFillUsername(login, expectedUsername: context.expectedUsername)
        switch kind {
        case .password:
            return ResolvedSecret(value: login.password, offlineCapability: nil)
        case .oneTimeCode:
            guard !login.totpUri.isEmpty else { throw AutoFillSecretResolverError.descriptorDoesNotSupportValue }
            let value = try await liveTOTP(itemId: itemId, shareId: shareId, deadline: deadline, context: context, cacheUnavailable: lookup.cacheUnavailable)
            return ResolvedSecret(value: value, offlineCapability: nil)
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

    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<String> {
        let lookup = try await preferredCachedItem(itemId: itemId, vaultId: vaultId, context: context)
        if let cached = lookup.item {
            let result = try cached.map { item in
                guard case .login(let login) = item.content.content, !login.totpUri.isEmpty else { throw Error.unavailable }
                return try TOTPGenerator.code(from: login.totpUri, at: totpDate())
            }
            try checkRequest(context)
            return result
        }
        let deadline = try liveDeadline(context)
        let value = try await liveTOTP(itemId: itemId, shareId: shareId, deadline: deadline, context: context, cacheUnavailable: lookup.cacheUnavailable)
        return ResolvedSecret(value: value, offlineCapability: nil)
    }

    private func liveItem(
        itemId: String, shareId: String, deadline: CLIExecutionDeadline?, context: SecretResolutionContext, cacheUnavailable: Bool
    ) async throws -> CLIItem {
        do {
            let item: CLIItem
            if let deadline {
                item = try await live.viewItem(itemId: itemId, shareId: shareId, deadline: deadline)
            } else {
                item = try await live.viewItem(itemId: itemId, shareId: shareId)
            }
            try checkRequest(context)
            return item
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try checkRequest(context)
            if cacheUnavailable { throw Error.unavailable }
            throw error
        }
    }

    private func liveTOTP(
        itemId: String, shareId: String, deadline: CLIExecutionDeadline?, context: SecretResolutionContext, cacheUnavailable: Bool
    ) async throws -> String {
        do {
            let value: String
            if let deadline {
                value = try await live.getTotp(itemId: itemId, shareId: shareId, deadline: deadline)
            } else {
                value = try await live.getTotp(itemId: itemId, shareId: shareId)
            }
            try checkRequest(context)
            return value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try checkRequest(context)
            if cacheUnavailable { throw Error.unavailable }
            throw error
        }
    }

    private struct CacheLookup {
        let item: ResolvedSecret<CLIItem>?
        let cacheUnavailable: Bool
    }

    private enum CacheAvailability: Swift.Error { case unusable }

    private struct CacheDecodeFailure: Swift.Error {
        let snapshot: EncryptedOfflineSnapshot
        let error: OfflineSnapshotCodec.Error
        let capability: OfflineReleaseCapability
    }

    private func preferredCachedItem(
        itemId: String, vaultId: String, context: SecretResolutionContext
    ) async throws -> CacheLookup {
        try checkRequest(context)
        let key = OfflineSnapshotKey(vaultId: vaultId, itemId: itemId, schemaVersion: OfflineSnapshotLimits.schemaVersion)
        let admitted = try await usableSnapshotExists(for: key)
        try checkRequest(context)
        guard admitted else { return CacheLookup(item: nil, cacheUnavailable: false) }
        do {
            return CacheLookup(item: try await cachedItem(itemId: itemId, vaultId: vaultId, context: context), cacheUnavailable: false)
        } catch is CacheAvailability {
            // Only explicit key/decode availability may cross back to live after admission.
            try checkRequest(context)
            return CacheLookup(item: nil, cacheUnavailable: true)
        }
    }

    private func liveDeadline(_ context: SecretResolutionContext) throws -> CLIExecutionDeadline? {
        try checkRequest(context)
        return try OfflineAutoFillLiveBudget.deadline(context: context, now: now())
    }

    private func checkRequest(_ context: SecretResolutionContext) throws {
        try Task.checkCancellation()
        try checkDeadline(context)
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
        try checkRequest(context)
        let ready = await readiness.isReady()
        try checkRequest(context)
        guard ready else { throw Error.unavailable }
        let key = OfflineSnapshotKey(vaultId: vaultId, itemId: itemId, schemaVersion: OfflineSnapshotLimits.schemaVersion)
        var availabilityEvidence: OfflineReleaseCapability?
        var cacheOnly = false
        for attempt in 0...1 {
            try checkRequest(context)
            do {
                if let result = try await cachedAttempt(key: key, context: context) { return result }
                cacheOnly = true
            } catch is OfflineReleaseError {
                // Fresh capture and proofs may resolve a replacement, but never permit live.
                cacheOnly = true
            } catch is CancellationError {
                throw CancellationError()
            } catch SecretResolutionError.deadlineExpired {
                throw SecretResolutionError.deadlineExpired
            } catch let failure as CacheDecodeFailure {
                do {
                    try await retryDecodeFailure(failure, attempt: attempt, context: context,
                        evidence: cacheOnly ? nil : (availabilityEvidence ?? failure.capability))
                    availabilityEvidence = availabilityEvidence ?? failure.capability
                } catch is OfflineReleaseError {
                    cacheOnly = true
                    availabilityEvidence = nil
                }
            } catch let error as AutoFillSecretResolverError {
                throw error
            } catch {
                try checkRequest(context)
                throw Error.unavailable
            }
        }
        try checkRequest(context)
        throw Error.unavailable
    }

    private func cachedAttempt(
        key: OfflineSnapshotKey, context: SecretResolutionContext
    ) async throws -> ResolvedSecret<CLIItem>? {
        let capture = releaseAuthority.capture(for: key)
        guard let snapshot = try await repository.authorizedSnapshot(for: key),
              let initialProof = try await repository.releaseProof(for: snapshot) else { return nil }
        try releaseAuthority.bind(capture, proof: initialProof)
        let item: CLIItem
        do {
            item = try await codec.decodeSnapshot(snapshot)
        } catch let error as OfflineSnapshotCodec.Error {
            try checkRequest(context)
            // Decode availability cannot override a concurrent authorization loss.
            guard let proof = try await repository.releaseProof(for: snapshot) else { throw OfflineReleaseError.revoked }
            let capability = try releaseAuthority.authorize(capture, proof: proof)
            throw CacheDecodeFailure(snapshot: snapshot, error: error, capability: capability)
        }
        try checkRequest(context)
        try validateCachedUsername(item, context: context)
        guard item.content.content.itemType == initialProof.itemType,
              let proof = try await repository.releaseProof(for: snapshot) else { return nil }
        let capability = try releaseAuthority.authorize(capture, proof: proof)
        try checkRequest(context)
        return ResolvedSecret(value: item, offlineCapability: capability)
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
}

extension OfflineSecretResolver {
    private func retryDecodeFailure(
        _ failure: CacheDecodeFailure, attempt: Int, context: SecretResolutionContext, evidence: OfflineReleaseCapability?
    ) async throws {
        try checkRequest(context)
        switch failure.error {
        case .keyUnavailable, .corruptSnapshot:
            if try await shouldRetryDecodeFailure(failure, attempt: attempt, context: context) { return }
            guard let evidence else { throw Error.unavailable }
            // Linearize only the non-secret source choice while original authority is valid.
            // No repository work or suspension may run in this one-shot effect.
            try evidence.withRelease(validating: { try checkRequest(context) }, effect: {})
            // Owned cleanup follows the completed source choice, never precedes its authorization.
            if failure.error == .corruptSnapshot { try? await repository.discardCorruptSnapshot(failure.snapshot) }
            try checkRequest(context)
            throw CacheAvailability.unusable
        case .invalidIdentity, .payloadTooLarge, .unsupportedSchemaVersion:
            if shouldDiscard(failure.error) { try? await repository.discardCorruptSnapshot(failure.snapshot) }
            try checkRequest(context)
            throw Error.unavailable
        }
    }

    private func shouldRetryDecodeFailure(
        _ failure: CacheDecodeFailure, attempt: Int, context: SecretResolutionContext
    ) async throws -> Bool {
        do {
            guard try await repository.hasAuthorizedSnapshot(for: failure.snapshot.identity.key) else { throw Error.unavailable }
            guard attempt == 0 else { return false }
            if failure.error == .keyUnavailable { return true }
            return try await !repository.isAuthorized(failure.snapshot)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try checkRequest(context)
            throw Error.unavailable
        }
    }

    private nonisolated func shouldDiscard(_ error: OfflineSnapshotCodec.Error) -> Bool {
        switch error {
        case .corruptSnapshot, .invalidIdentity: true
        case .keyUnavailable, .payloadTooLarge, .unsupportedSchemaVersion: false
        }
    }

    enum Error: Swift.Error, LocalizedError, Equatable, Sendable {
        case unavailable

        var errorDescription: String? {
            String(localized: "Not available offline. Sign in to Proton Pass or reconnect, then try again.")
        }
    }

    init(
        cliService: PassCLIService,
        repository: any OfflineSnapshotPersisting,
        codec: any OfflineSnapshotCoding,
        readiness: any OfflineInitializationProviding
    ) {
        self.init(live: cliService, repository: repository, codec: codec, readiness: readiness)
    }
}
