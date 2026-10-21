import Foundation

nonisolated enum AutoFillCredentialProviderError: Equatable, Sendable {
    case userCanceled
    case userInteractionRequired
    case credentialIdentityNotFound
    case failed
}

/// Testable boundary around Authentication Services' password/code-only completion APIs.
@MainActor
protocol CredentialProviding: AnyObject, Sendable {
    func completePassword(user: String, password: String) async throws
    func completeOneTimeCode(_ code: String) async throws
    func cancelRequest(with error: AutoFillCredentialProviderError)
}

/// Keeps silent and interactive Authentication Services callbacks on distinct paths.
@MainActor
enum AutoFillCredentialRequestPolicy {
    /// A silent request must not wait for the broker or surface UI.
    static func requireUserInteraction(using provider: any CredentialProviding) {
        provider.cancelRequest(with: .userInteractionRequired)
    }
}

/// Owns the single system-context terminal right for the currently active request.
/// A provider scoped to a superseded token silently loses that right.
@MainActor
final class AutoFillCredentialRequestGate {
    private let provider: any CredentialProviding
    private var activeToken: UUID?
    private var isTerminal = false

    init(provider: any CredentialProviding) {
        self.provider = provider
    }

    func beginRequest() -> UUID {
        let token = UUID()
        activeToken = token
        isTerminal = false
        return token
    }

    func provider(for token: UUID) -> any CredentialProviding {
        TokenScopedCredentialProvider(gate: self, token: token)
    }

    func finishRequest(_ token: UUID) {
        guard activeToken == token else { return }
        activeToken = nil
        isTerminal = true
    }

    fileprivate func completePassword(
        token: UUID,
        user: String,
        password: String
    ) async throws {
        guard claimTerminal(token) else { throw CancellationError() }
        try await provider.completePassword(user: user, password: password)
    }

    fileprivate func completeOneTimeCode(token: UUID, code: String) async throws {
        guard claimTerminal(token) else { throw CancellationError() }
        try await provider.completeOneTimeCode(code)
    }

    fileprivate func cancel(token: UUID, error: AutoFillCredentialProviderError) {
        guard claimTerminal(token) else { return }
        provider.cancelRequest(with: error)
    }

    private func claimTerminal(_ token: UUID) -> Bool {
        guard activeToken == token, isTerminal == false else { return false }
        isTerminal = true
        return true
    }
}

@MainActor
private final class TokenScopedCredentialProvider: CredentialProviding {
    private let gate: AutoFillCredentialRequestGate
    private let token: UUID

    init(gate: AutoFillCredentialRequestGate, token: UUID) {
        self.gate = gate
        self.token = token
    }

    func completePassword(user: String, password: String) async throws {
        try await gate.completePassword(token: token, user: user, password: password)
    }

    func completeOneTimeCode(_ code: String) async throws {
        try await gate.completeOneTimeCode(token: token, code: code)
    }

    func cancelRequest(with error: AutoFillCredentialProviderError) {
        gate.cancel(token: token, error: error)
    }
}

/// Main-actor bridge from a system-selected opaque identity to the broker client.
/// Credential-list preparation deliberately performs no selection: the system picker owns it.
@MainActor
final class AutoFillExtensionCoordinator: AutoFillCandidatePickerCompleting {
    private static let requestLifetimeNanoseconds: UInt64 = 30_000_000_000

    private let resolver: any AutoFillBrokerResolving
    private let provider: any CredentialProviding
    private let now: @Sendable () -> UInt64

    init(
        resolver: any AutoFillBrokerResolving,
        provider: any CredentialProviding,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.resolver = resolver
        self.provider = provider
        self.now = now
    }

    func prepareCredentialListForSystemPicker() {
        // Registered ASPasswordCredentialIdentity values remain owned by the system picker.
    }

    func prepareOneTimeCodeCredentialListForSystemPicker() {
        // Registered ASOneTimeCodeCredentialIdentity values remain owned by the system picker.
    }

    func provide(
        candidate: AutoFillCandidate,
        appAssociationIntent: AutoFillAppAssociationIntent?
    ) async {
        switch candidate.kind {
        case .password:
            await providePassword(
                recordIdentifier: candidate.descriptorID.uuidString,
                username: candidate.username,
                appAssociationIntent: appAssociationIntent
            )
        case .oneTimeCode:
            await provideOneTimeCode(
                recordIdentifier: candidate.descriptorID.uuidString,
                appAssociationIntent: appAssociationIntent
            )
        }
    }

    func providePassword(
        recordIdentifier: String?,
        username: String,
        appAssociationIntent: AutoFillAppAssociationIntent? = nil
    ) async {
        guard let descriptorID = descriptorID(from: recordIdentifier) else {
            provider.cancelRequest(with: .credentialIdentityNotFound)
            return
        }
        let deadline = requestDeadline()
        var didBeginSystemCompletion = false
        do {
            let value = try await resolver.resolve(
                descriptorID: descriptorID,
                kind: .password,
                deadline: deadline,
                appAssociationIntent: appAssociationIntent
            )
            try Task.checkCancellation()
            didBeginSystemCompletion = true
            try await provider.completePassword(user: username, password: value)
        } catch is CancellationError {
            if didBeginSystemCompletion == false {
                provider.cancelRequest(with: .userCanceled)
            }
        } catch {
            if didBeginSystemCompletion == false {
                provider.cancelRequest(with: map(error))
            }
        }
    }

    func provideOneTimeCode(
        recordIdentifier: String?,
        appAssociationIntent: AutoFillAppAssociationIntent? = nil
    ) async {
        guard let descriptorID = descriptorID(from: recordIdentifier) else {
            provider.cancelRequest(with: .credentialIdentityNotFound)
            return
        }
        let deadline = requestDeadline()
        var didBeginSystemCompletion = false
        do {
            let value = try await resolver.resolve(
                descriptorID: descriptorID,
                kind: .oneTimeCode,
                deadline: deadline,
                appAssociationIntent: appAssociationIntent
            )
            try Task.checkCancellation()
            didBeginSystemCompletion = true
            try await provider.completeOneTimeCode(value)
        } catch is CancellationError {
            if didBeginSystemCompletion == false {
                provider.cancelRequest(with: .userCanceled)
            }
        } catch {
            if didBeginSystemCompletion == false {
                provider.cancelRequest(with: map(error))
            }
        }
    }

    private func descriptorID(from recordIdentifier: String?) -> UUID? {
        guard let recordIdentifier else { return nil }
        return UUID(uuidString: recordIdentifier)
    }

    private func requestDeadline() -> UInt64 {
        let current = now()
        let (deadline, overflow) = current.addingReportingOverflow(
            Self.requestLifetimeNanoseconds
        )
        return overflow ? UInt64.max : deadline
    }

    private func map(_ error: any Error) -> AutoFillCredentialProviderError {
        guard let clientError = error as? AutoFillBrokerClientError else { return .failed }
        switch clientError {
        case .brokerFailure(.invalidRequest), .brokerFailure(.resolutionFailed):
            return .credentialIdentityNotFound
        case .brokerFailure, .unavailable, .unauthorized, .expired, .invalidResponse:
            return .failed
        }
    }
}
