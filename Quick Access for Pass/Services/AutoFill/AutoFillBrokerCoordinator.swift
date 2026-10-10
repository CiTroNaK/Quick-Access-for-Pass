import Foundation

nonisolated protocol AutoFillAppAssociationStoring: Sendable {
    func save(
        service: AutoFillServiceIdentifier,
        descriptorID: UUID,
        createdAt: Date
    ) async throws
}

extension AutoFillAppAssociationStore: AutoFillAppAssociationStoring {}

nonisolated enum AutoFillAccessibilityEvent: CaseIterable, Equatable, Sendable {
    case unlockRequired
    case requestTimedOut
    case cliFailure

    var announcement: String {
        switch self {
        case .unlockRequired:
            String(localized: "Unlock Quick Access to continue AutoFill.")
        case .requestTimedOut:
            String(localized: "AutoFill timed out. Try again.")
        case .cliFailure:
            String(localized: "AutoFill could not retrieve the credential from Proton Pass.")
        }
    }
}

@MainActor
protocol AutoFillAccessibilityPresenting: Sendable {
    func announce(_ event: AutoFillAccessibilityEvent)
    func recoverFocusAfterAuthenticationFailure()
}

private struct NoOpAutoFillAccessibilityAdapter: AutoFillAccessibilityPresenting {
    func announce(_ event: AutoFillAccessibilityEvent) {}
    func recoverFocusAfterAuthenticationFailure() {}
}

@MainActor
final class AutoFillBrokerCoordinator {
    private static let maximumRequestLifetimeNanoseconds: UInt64 = 30_000_000_000

    nonisolated enum Error: Swift.Error, Equatable, Sendable {
        case deadlineExpired
        case descriptorNotFound
        case unlockFailed
    }

    typealias LockedState = @MainActor @Sendable () -> Bool
    typealias ShowLockedPanel = @MainActor @Sendable (TimeInterval) async -> Bool

    private let descriptorStore: any AutoFillDescriptorStoring
    private let associationStore: (any AutoFillAppAssociationStoring)?
    private let secretResolver: any AutoFillSecretResolving
    private let secretReleaseGuard: SecretReleaseGuard
    private let isAppLocked: LockedState
    private let showLockedPanel: ShowLockedPanel
    private let accessibility: any AutoFillAccessibilityPresenting
    private let now: @Sendable () -> UInt64

    init(
        descriptorStore: any AutoFillDescriptorStoring,
        associationStore: (any AutoFillAppAssociationStoring)? = nil,
        secretResolver: any AutoFillSecretResolving,
        secretReleaseGuard: SecretReleaseGuard = SecretReleaseGuard(),
        isAppLocked: @escaping LockedState,
        showLockedPanel: @escaping ShowLockedPanel,
        accessibility: (any AutoFillAccessibilityPresenting)? = nil,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.descriptorStore = descriptorStore
        self.associationStore = associationStore
        self.secretResolver = secretResolver
        self.secretReleaseGuard = secretReleaseGuard
        self.isAppLocked = isAppLocked
        self.showLockedPanel = showLockedPanel
        self.accessibility = accessibility ?? NoOpAutoFillAccessibilityAdapter()
        self.now = now
    }

    /// Resolves metadata before entering either unlock UI or Pass CLI. Every
    /// suspension is bounded by the request's original monotonic deadline.
    func listCandidates(query: AutoFillCandidateQuery) async throws -> [AutoFillCandidate] {
        try requireRemainingTime(until: query.deadlineUptimeNanoseconds)
        let store = descriptorStore
        let candidates = try await beforeDeadline(query.deadlineUptimeNanoseconds) {
            try await store.candidates(for: query)
        }
        guard candidates.count <= AutoFillCandidate.maximumCandidates else {
            throw AutoFillProtocolError.malformedMessage
        }
        return candidates
    }

    func resolve(
        request: AutoFillRegisteredRequest,
        appAssociationIntent: AutoFillAppAssociationIntent? = nil,
        transition: AutoFillBrokerStateTransition = { _ in }
    ) async throws -> ResolvedSecret<String> {
        try await resolveDelivery(
            request: request,
            appAssociationIntent: appAssociationIntent,
            transition: transition
        ).value
    }

    /// Produces a transient value paired with the only allowed final IPC
    /// release capability. The processor must call that capability only after
    /// its registry completion linearization.
    func resolveDelivery(
        request: AutoFillRegisteredRequest,
        appAssociationIntent: AutoFillAppAssociationIntent? = nil,
        transition: AutoFillBrokerStateTransition = { _ in }
    ) async throws -> AutoFillCredentialDelivery {
        let releaseToken = secretReleaseGuard.capture()
        do {
            let resolved = try await resolveRequest(
                request,
                releaseToken: releaseToken,
                appAssociationIntent: appAssociationIntent,
                transition: transition
            )
            return AutoFillCredentialDelivery(
                value: resolved.value,
                release: AutoFillCredentialRelease(
                    request: request,
                    descriptor: resolved.descriptor,
                    releaseToken: releaseToken,
                    descriptorStore: descriptorStore,
                    secretReleaseGuard: secretReleaseGuard,
                    isAppLocked: isAppLocked,
                    now: now
                )
            )
        } catch Error.deadlineExpired {
            accessibility.announce(.requestTimedOut)
            throw Error.deadlineExpired
        }
    }

    private func resolveRequest(
        _ request: AutoFillRegisteredRequest,
        releaseToken: UUID,
        appAssociationIntent: AutoFillAppAssociationIntent?,
        transition: AutoFillBrokerStateTransition
    ) async throws -> AutoFillResolvedCredential {
        try Task.checkCancellation()
        try requireRemainingTime(until: request.deadline)

        let store = descriptorStore
        let descriptor = try await beforeDeadline(request.deadline) {
            try await store.descriptor(id: request.descriptorID)
        }
        guard let descriptor else { throw Error.descriptorNotFound }
        try requireCurrentGuard(releaseToken)

        if let appAssociationIntent {
            guard appAssociationIntent.service.kind == .app,
                  let associationStore else {
                throw AutoFillProtocolError.malformedMessage
            }
            try await beforeDeadline(request.deadline) {
                try await associationStore.save(
                    service: appAssociationIntent.service,
                    descriptorID: descriptor.id,
                    createdAt: Date()
                )
            }
            try requireCurrentGuard(releaseToken)
        }

        try Task.checkCancellation()
        if isAppLocked() {
            accessibility.announce(.unlockRequired)
            try await transition(.awaitingUnlock)
            try requireCurrentGuard(releaseToken)
            let timeout = try remainingSeconds(until: request.deadline)
            let unlocked = try await beforeDeadline(request.deadline) {
                await self.showLockedPanel(timeout)
            }
            try Task.checkCancellation()
            try requireCurrentGuard(releaseToken)
            guard unlocked else {
                accessibility.recoverFocusAfterAuthenticationFailure()
                throw Error.unlockFailed
            }
        }

        try requireRemainingTime(until: request.deadline)
        try requireCurrentGuard(releaseToken)
        try await transition(.resolving)
        try Task.checkCancellation()
        try requireCurrentGuard(releaseToken)

        let resolver = secretResolver
        let context = SecretResolutionContext(
            deadlineUptimeNanoseconds: request.deadline,
            expectedUsername: descriptor.username
        )
        do {
            // Native secret resolution receives the original deadline itself;
            // wrapping it in a timer task would leave an unbounded child alive.
            let value = try await resolver.resolve(descriptor: descriptor, kind: request.kind, context: context)
            try Task.checkCancellation()
            try requireRemainingTime(until: request.deadline)
            try requireCurrentGuard(releaseToken)

            // Re-read metadata after decryption/resolution so stale identity or
            // capability changes cannot authorize the final broker release.
            let currentDescriptor = try await beforeDeadline(request.deadline) {
                try await store.descriptor(id: request.descriptorID)
            }
            guard let currentDescriptor,
                  currentDescriptor.id == descriptor.id,
                  currentDescriptor.identityKey == descriptor.identityKey,
                  supports(request.kind, descriptor: currentDescriptor)
            else {
                throw Error.descriptorNotFound
            }
            try Task.checkCancellation()
            try requireRemainingTime(until: request.deadline)
            try requireFinalRelease(releaseToken)
            return AutoFillResolvedCredential(value: value, descriptor: descriptor)
        } catch is SecretResolutionError {
            throw Error.deadlineExpired
        } catch Error.deadlineExpired {
            throw Error.deadlineExpired
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            accessibility.announce(.cliFailure)
            throw error
        }
    }

    private func requireRemainingTime(until deadline: UInt64) throws {
        _ = try remainingNanoseconds(until: deadline)
    }

    private func requireCurrentGuard(_ token: UUID) throws {
        guard secretReleaseGuard.isCurrent(token) else { throw CancellationError() }
    }

    private func requireFinalRelease(_ token: UUID) throws {
        try requireCurrentGuard(token)
        guard !isAppLocked() else { throw Error.unlockFailed }
    }

    private func supports(_ kind: AutoFillValueKind, descriptor: AutoFillCredentialDescriptor) -> Bool {
        switch kind {
        case .password: true
        case .oneTimeCode: descriptor.hasTOTP
        }
    }

    private func remainingSeconds(until deadline: UInt64) throws -> TimeInterval {
        TimeInterval(try remainingNanoseconds(until: deadline)) / 1_000_000_000
    }

    private func remainingNanoseconds(until deadline: UInt64) throws -> UInt64 {
        let current = now()
        guard deadline > current else { throw Error.deadlineExpired }
        let remaining = deadline - current
        guard remaining <= Self.maximumRequestLifetimeNanoseconds else {
            throw Error.deadlineExpired
        }
        return remaining
    }

    private func beforeDeadline<Value: Sendable>(
        _ deadline: UInt64,
        operation: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        let remaining = try remainingNanoseconds(until: deadline)
        let remainingDuration = Duration.nanoseconds(Int64(remaining))

        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: remainingDuration)
                throw Error.deadlineExpired
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw CancellationError()
            }
            return first
        }
    }
}
