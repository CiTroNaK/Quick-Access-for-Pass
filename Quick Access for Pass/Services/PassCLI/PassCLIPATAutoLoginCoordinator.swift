import Foundation

@MainActor
final class PassCLIPATAutoLoginCoordinator: PassCLIHealthTransitionHandling {
    private let credentialStore: any PassCLIPATCredentialStoring
    private let sessionMutationGate: PassCLISessionMutationGate
    private let currentHealth: @MainActor @Sendable () -> PassCLIHealth
    private let loginWithSavedToken: @MainActor @Sendable (PassCLISessionMutationGate.Lease) async -> PassCLIPATLoginResult
    private let fallbackHandler: any PassCLIHealthTransitionHandling
    private let patFailureHandler: @MainActor @Sendable (String) -> Void
    private let invalidPATHandler: @MainActor @Sendable (String) -> Void
    private let autoLoginStartedHandler: @MainActor @Sendable () -> Void

    private var attemptedInCurrentLoggedOutEpisode = false
    private var currentAttempt: Task<Void, Never>?

    init(
        credentialStore: any PassCLIPATCredentialStoring,
        sessionMutationGate: PassCLISessionMutationGate,
        currentHealth: @escaping @MainActor @Sendable () -> PassCLIHealth,
        loginWithSavedToken: @escaping @MainActor @Sendable (PassCLISessionMutationGate.Lease) async -> PassCLIPATLoginResult,
        fallbackHandler: any PassCLIHealthTransitionHandling,
        patFailureHandler: @escaping @MainActor @Sendable (String) -> Void,
        invalidPATHandler: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        autoLoginStartedHandler: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.credentialStore = credentialStore
        self.sessionMutationGate = sessionMutationGate
        self.currentHealth = currentHealth
        self.loginWithSavedToken = loginWithSavedToken
        self.fallbackHandler = fallbackHandler
        self.patFailureHandler = patFailureHandler
        self.invalidPATHandler = invalidPATHandler
        self.autoLoginStartedHandler = autoLoginStartedHandler
    }

    func handleCLIHealthTransition(to health: PassCLIHealth) {
        switch health {
        case .notLoggedIn, .localSessionUnreadable:
            startAutomaticAttemptIfNeeded()
        case .ok:
            attemptedInCurrentLoggedOutEpisode = false
            fallbackHandler.handleCLIHealthTransition(to: health)
        case .notInstalled, .failed:
            fallbackHandler.handleCLIHealthTransition(to: health)
        }
    }

    func waitForCurrentAttempt() async {
        await currentAttempt?.value
    }

    private func startAutomaticAttemptIfNeeded() {
        guard !attemptedInCurrentLoggedOutEpisode, currentAttempt == nil else { return }
        guard currentHealth().requiresAuthenticationRecovery else { return }
        guard let lease = sessionMutationGate.tryAcquire(.savedTokenLogin) else { return }
        let gate = sessionMutationGate
        currentAttempt = Task { @MainActor [weak self] in
            defer { gate.release(lease) }
            guard let self else { return }
            defer { self.currentAttempt = nil }

            let hasToken: Bool
            do {
                hasToken = try await self.credentialStore.hasToken()
            } catch {
                // Unavailable is not absent. Recheck on a later health tick,
                // without consuming the episode or prompting browser sign-in.
                return
            }
            guard !Task.isCancelled, gate.owns(lease) else { return }
            let health = self.currentHealth()
            guard health.requiresAuthenticationRecovery else { return }
            guard hasToken else {
                self.fallbackHandler.handleCLIHealthTransition(to: health)
                return
            }

            self.attemptedInCurrentLoggedOutEpisode = true
            self.autoLoginStartedHandler()
            let result = await self.loginWithSavedToken(lease)
            guard !Task.isCancelled else { return }
            self.handleResult(result)
        }
    }

    private func handleResult(_ result: PassCLIPATLoginResult) {
        switch result {
        case .succeeded:
            return
        case .busy:
            attemptedInCurrentLoggedOutEpisode = false
        case .missingToken:
            attemptedInCurrentLoggedOutEpisode = false
            fallbackHandler.handleCLIHealthTransition(to: currentHealth())
        case .notInstalled:
            fallbackHandler.handleCLIHealthTransition(to: .notInstalled)
        case .invalidToken:
            patFailureHandler(result.userFacingMessage)
            invalidPATHandler(result.userFacingMessage)
        case .timeout, .failed, .healthStillNotOK:
            // Saved-PAT failures belong to PAT presentation, not browser login.
            patFailureHandler(result.userFacingMessage)
        }
    }
}
