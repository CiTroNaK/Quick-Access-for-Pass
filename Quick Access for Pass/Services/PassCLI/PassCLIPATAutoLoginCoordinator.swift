import Foundation

@MainActor
final class PassCLIPATAutoLoginCoordinator: PassCLIHealthTransitionHandling {
    private let credentialStore: any PassCLIPATCredentialStoring
    private let loginWithSavedToken: @MainActor @Sendable () async -> PassCLIPATLoginResult
    private let fallbackHandler: any PassCLIHealthTransitionHandling
    private let patFailureHandler: @MainActor @Sendable (String) -> Void
    private let invalidPATHandler: @MainActor @Sendable (String) -> Void
    private let autoLoginStartedHandler: @MainActor @Sendable () -> Void
    private let browserLoginIsRunning: @MainActor @Sendable () -> Bool

    private var attemptedInCurrentLoggedOutEpisode = false
    private var currentAttempt: Task<Void, Never>?

    init(
        credentialStore: any PassCLIPATCredentialStoring,
        loginWithSavedToken: @escaping @MainActor @Sendable () async -> PassCLIPATLoginResult,
        fallbackHandler: any PassCLIHealthTransitionHandling,
        patFailureHandler: @escaping @MainActor @Sendable (String) -> Void,
        invalidPATHandler: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        autoLoginStartedHandler: @escaping @MainActor @Sendable () -> Void = {},
        browserLoginIsRunning: @escaping @MainActor @Sendable () -> Bool
    ) {
        self.credentialStore = credentialStore
        self.loginWithSavedToken = loginWithSavedToken
        self.fallbackHandler = fallbackHandler
        self.patFailureHandler = patFailureHandler
        self.invalidPATHandler = invalidPATHandler
        self.autoLoginStartedHandler = autoLoginStartedHandler
        self.browserLoginIsRunning = browserLoginIsRunning
    }

    func handleCLIHealthTransition(to health: PassCLIHealth) {
        switch health {
        case .notLoggedIn:
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
        guard attemptedInCurrentLoggedOutEpisode == false else { return }
        guard currentAttempt == nil else { return }
        guard browserLoginIsRunning() == false else {
            fallbackHandler.handleCLIHealthTransition(to: .notLoggedIn)
            return
        }

        currentAttempt = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.currentAttempt = nil }

            guard await self.credentialStore.hasToken() else {
                self.fallbackHandler.handleCLIHealthTransition(to: .notLoggedIn)
                return
            }

            self.attemptedInCurrentLoggedOutEpisode = true
            self.autoLoginStartedHandler()
            let result = await self.loginWithSavedToken()
            switch result {
            case .succeeded:
                return
            case .missingToken:
                self.fallbackHandler.handleCLIHealthTransition(to: .notLoggedIn)
            case .notInstalled:
                self.fallbackHandler.handleCLIHealthTransition(to: .notInstalled)
            case .invalidToken:
                self.patFailureHandler(result.userFacingMessage)
                self.invalidPATHandler(result.userFacingMessage)
            case .timeout, .failed, .healthStillNotOK:
                self.patFailureHandler(result.userFacingMessage)
                self.fallbackHandler.handleCLIHealthTransition(to: .notLoggedIn)
            }
        }
    }
}
