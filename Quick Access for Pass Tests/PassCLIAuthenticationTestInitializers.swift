import Foundation
@testable import Quick_Access_for_Pass

// Isolated unit fixtures get a fresh gate. Cross-entrypoint tests must instead
// use the production initializers and explicitly share one gate.
extension PassCLIPATLoginService {
    convenience init(
        credentialStore: any PassCLIPATCredentialStoring,
        runner: any CLIEnvironmentRunning = LiveCLIRunner(),
        cliService: PassCLIService,
        healthRefresher: any PassCLIHealthRefreshing,
        syncTrigger: @escaping @MainActor @Sendable () async -> Void,
        revokeTransientSecretAccess: @escaping @MainActor @Sendable () -> Void = {},
        timeoutSeconds: TimeInterval = 30
    ) {
        self.init(
            sessionMutationGate: PassCLISessionMutationGate(), credentialStore: credentialStore,
            runner: runner, cliService: cliService, healthRefresher: healthRefresher,
            syncTrigger: syncTrigger, revokeTransientSecretAccess: revokeTransientSecretAccess,
            timeoutSeconds: timeoutSeconds
        )
    }
}

extension PassCLILoginCoordinator {
    convenience init(
        cliService: PassCLIService,
        currentHealth: @escaping @MainActor @Sendable () -> PassCLIHealth = { .localSessionUnreadable },
        runner: any CLIStreaming = LiveCLIStreamingRunner(),
        sessionResetRunner: any CLIRunning = LiveCLIRunner(),
        urlOpener: any URLOpening = WorkspaceURLOpener(),
        healthRefresher: any PassCLIHealthRefreshing,
        syncTrigger: @escaping @MainActor @Sendable () async -> Void,
        resultHandler: @escaping @MainActor @Sendable (PassCLILoginResult) -> Void,
        revokeTransientSecretAccess: @escaping @MainActor @Sendable () -> Void = {},
        urlDiscoveryTimeout: Duration = .seconds(15),
        loginCompletionTimeout: Duration = .seconds(300)
    ) {
        self.init(
            sessionMutationGate: PassCLISessionMutationGate(), cliService: cliService,
            currentHealth: currentHealth, runner: runner, sessionResetRunner: sessionResetRunner, urlOpener: urlOpener,
            healthRefresher: healthRefresher, syncTrigger: syncTrigger, resultHandler: resultHandler,
            revokeTransientSecretAccess: revokeTransientSecretAccess,
            urlDiscoveryTimeout: urlDiscoveryTimeout, loginCompletionTimeout: loginCompletionTimeout
        )
    }
}

extension PassCLIPATSettingsModel {
    convenience init(
        credentialStore: any PassCLIPATCredentialStoring,
        loginWithSavedToken: @escaping @MainActor @Sendable () async -> PassCLIPATLoginResult,
        invalidPATHandler: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        isCurrentSessionPersonalAccessToken: @escaping @MainActor @Sendable () -> Bool = { false },
        logoutFromPassCLI: @escaping @MainActor @Sendable () async throws -> Void = {}
    ) {
        self.init(
            sessionMutationGate: PassCLISessionMutationGate(), credentialStore: credentialStore,
            loginWithSavedToken: { _ in await loginWithSavedToken() }, invalidPATHandler: invalidPATHandler,
            isCurrentSessionPersonalAccessToken: isCurrentSessionPersonalAccessToken,
            logoutFromPassCLI: { _ in try await logoutFromPassCLI() }
        )
    }
}

extension PassCLIPATAutoLoginCoordinator {
    convenience init(
        credentialStore: any PassCLIPATCredentialStoring,
        loginWithSavedToken: @escaping @MainActor @Sendable () async -> PassCLIPATLoginResult,
        fallbackHandler: any PassCLIHealthTransitionHandling,
        patFailureHandler: @escaping @MainActor @Sendable (String) -> Void,
        invalidPATHandler: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        autoLoginStartedHandler: @escaping @MainActor @Sendable () -> Void = {},
        browserLoginIsRunning: @escaping @MainActor @Sendable () -> Bool
    ) {
        precondition(!browserLoginIsRunning(), "Contention fixtures must explicitly share a production gate.")
        let gate = PassCLISessionMutationGate()
        self.init(
            credentialStore: credentialStore, sessionMutationGate: gate, currentHealth: { .notLoggedIn },
            loginWithSavedToken: { _ in await loginWithSavedToken() }, fallbackHandler: fallbackHandler,
            patFailureHandler: patFailureHandler, invalidPATHandler: invalidPATHandler,
            autoLoginStartedHandler: autoLoginStartedHandler
        )
    }
}
