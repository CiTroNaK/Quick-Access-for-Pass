import Foundation

nonisolated enum PassCLIPATLoginResult: Sendable, Equatable {
    case succeeded
    case busy
    case missingToken
    case notInstalled
    case timeout
    case invalidToken
    case failed(String)
    case healthStillNotOK(String)

    var userFacingMessage: String {
        switch self {
        case .succeeded:
            return String(localized: "Proton Pass CLI connected")
        case .busy:
            return String(localized: "Sign-in already in progress.")
        case .missingToken:
            return String(localized: "No personal access token is saved.")
        case .notInstalled:
            return String(localized: "pass-cli is not installed.")
        case .timeout:
            return String(localized: "Personal access token login timed out.")
        case .invalidToken:
            return String(localized: "Personal access token is invalid, expired, or deleted. Replace it in Settings → Pass CLI or log in normally.")
        case .failed(let message):
            return message
        case .healthStillNotOK(let message):
            return message
        }
    }
}

nonisolated struct PassCLIPATOutputSanitizer: Sendable {
    let token: String

    func isInvalidExpiredOrDeletedPAT(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("personal access token is invalid, expired or has been deleted")
    }

    func sanitize(_ text: String, limit: Int = 180) -> String {
        let assignmentRedacted = text.replacingOccurrences(
            of: #"PROTON_PASS_PERSONAL_ACCESS_TOKEN=\S+"#,
            with: "[PAT redacted]",
            options: .regularExpression
        )
        let tokenRedacted = assignmentRedacted.replacingOccurrences(of: token, with: "[PAT redacted]")
        let stripped = tokenRedacted.replacingOccurrences(
            of: #"\x1B\[[0-9;]*[a-zA-Z]|\[\d+m"#,
            with: "",
            options: .regularExpression
        )
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "..."
    }
}

@MainActor
final class PassCLIPATLoginService {
    private let sessionMutationGate: PassCLISessionMutationGate
    private let credentialStore: any PassCLIPATCredentialStoring
    private let runner: any CLIEnvironmentRunning
    private let cliService: PassCLIService
    private let healthRefresher: any PassCLIHealthRefreshing
    private let syncTrigger: @MainActor @Sendable () async -> Void
    private let revokeTransientSecretAccess: @MainActor @Sendable () -> Void
    private let timeoutSeconds: TimeInterval
    private var isLoggingIn = false

    init(
        sessionMutationGate: PassCLISessionMutationGate,
        credentialStore: any PassCLIPATCredentialStoring,
        runner: any CLIEnvironmentRunning = LiveCLIRunner(),
        cliService: PassCLIService,
        healthRefresher: any PassCLIHealthRefreshing,
        syncTrigger: @escaping @MainActor @Sendable () async -> Void,
        revokeTransientSecretAccess: @escaping @MainActor @Sendable () -> Void = {},
        timeoutSeconds: TimeInterval = 30
    ) {
        self.sessionMutationGate = sessionMutationGate
        self.credentialStore = credentialStore
        self.runner = runner
        self.cliService = cliService
        self.healthRefresher = healthRefresher
        self.syncTrigger = syncTrigger
        self.revokeTransientSecretAccess = revokeTransientSecretAccess
        self.timeoutSeconds = timeoutSeconds
    }

    /// Uses a caller-owned saved-token lease, or acquires ownership for a standalone request.
    func loginWithSavedToken(
        triggerSync: Bool = true, lease callerLease: PassCLISessionMutationGate.Lease? = nil
    ) async -> PassCLIPATLoginResult {
        guard !isLoggingIn else { return .busy }
        guard let lease = callerLease ?? sessionMutationGate.tryAcquire(.savedTokenLogin) else { return .busy }
        guard lease.operation == .savedTokenLogin, sessionMutationGate.owns(lease) else { return .busy }
        isLoggingIn = true
        defer {
            isLoggingIn = false
            if callerLease == nil { sessionMutationGate.release(lease) }
        }
        return await performAdmittedLogin(triggerSync: triggerSync)
    }

    /// Executes while the caller retains the validated lease through the entire await.
    private func performAdmittedLogin(triggerSync: Bool) async -> PassCLIPATLoginResult {
        do {
            try Task.checkCancellation()
            guard let token = try await credentialStore.loadToken(), token.isEmpty == false else {
                return .missingToken
            }
            let sanitizer = PassCLIPATOutputSanitizer(token: token)
            do {
                try Task.checkCancellation()
                try await login(token: token, executablePath: cliService.cliPath)
            } catch CLIError.notInstalled {
                return .notInstalled
            } catch CLIError.timeout {
                return .timeout
            } catch {
                let message = error.localizedDescription
                if sanitizer.isInvalidExpiredOrDeletedPAT(message) {
                    return .invalidToken
                }
                return .failed(sanitizer.sanitize(message))
            }

            let health = await healthRefresher.refreshPassCLIHealth()
            guard health == .ok else {
                return .healthStillNotOK(String(localized: "Personal access token login finished, but Pass CLI is still not connected."))
            }

            if triggerSync {
                await syncTrigger()
            }
            return .succeeded
        } catch {
            return .failed(String(localized: "Could not read saved personal access token: \(error.localizedDescription)"))
        }
    }

    private func login(token: String, executablePath: String) async throws {
        let environment = ["PROTON_PASS_PERSONAL_ACCESS_TOKEN": token]
        do {
            _ = try await runner.run(
                executablePath: executablePath,
                arguments: ["login"],
                environmentOverrides: environment,
                timeout: timeoutSeconds
            )
            return
        } catch let error as CLIError where error.isLocalSessionDecryptionError {
            // Login reads the existing session before authenticating the PAT.
            // This specific failure proves that local session cannot be reused.
            try await resetLocalSessionAndRetryLogin(token: token, executablePath: executablePath)
        } catch CLIError.commandFailed(let message)
            where message.localizedCaseInsensitiveContains("already authenticated") {
            // A local session can block login even when it no longer works remotely.
            // Probe directly: publishing an intermediate health transition here could
            // start automatic PAT login while this recovery is still in progress.
            do {
                _ = try await runner.run(
                    executablePath: executablePath,
                    arguments: ["info", "--output", "json"],
                    environmentOverrides: [:],
                    timeout: PassCLISanityCheck.timeoutSeconds
                )
            } catch let error as CLIError where error.isAuthError {
                try await resetLocalSessionAndRetryLogin(token: token, executablePath: executablePath)
                return
            }
            // Healthy sessions must not be replaced or reported as a successful
            // login with the saved PAT: that token has not been validated yet.
            throw CLIError.commandFailed(message)
        }
    }

    /// Clears a confirmed unusable CLI session and attempts saved-token login exactly once.
    private func resetLocalSessionAndRetryLogin(token: String, executablePath: String) async throws {
        try Task.checkCancellation()
        // Forced logout invalidates the local Pass session; revoke transient
        // host secret delivery before starting its runner work.
        revokeTransientSecretAccess()
        _ = try await runner.run(
            executablePath: executablePath,
            arguments: ["logout", "--force"],
            environmentOverrides: [:],
            timeout: timeoutSeconds
        )
        try Task.checkCancellation()
        // Do not recurse through login's recovery handlers. The caller classifies
        // and sanitizes cleanup/retry errors, including an invalid replacement PAT.
        _ = try await runner.run(
            executablePath: executablePath,
            arguments: ["login"],
            environmentOverrides: ["PROTON_PASS_PERSONAL_ACCESS_TOKEN": token],
            timeout: timeoutSeconds
        )
    }
}
