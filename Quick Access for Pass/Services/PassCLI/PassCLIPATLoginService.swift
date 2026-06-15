import Foundation

nonisolated enum PassCLIPATLoginResult: Sendable, Equatable {
    case succeeded
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
    private let credentialStore: any PassCLIPATCredentialStoring
    private let runner: any CLIEnvironmentRunning
    private let cliService: PassCLIService
    private let healthRefresher: any PassCLIHealthRefreshing
    private let syncTrigger: @MainActor @Sendable () async -> Void
    private let timeoutSeconds: TimeInterval

    init(
        credentialStore: any PassCLIPATCredentialStoring,
        runner: any CLIEnvironmentRunning = LiveCLIRunner(),
        cliService: PassCLIService,
        healthRefresher: any PassCLIHealthRefreshing,
        syncTrigger: @escaping @MainActor @Sendable () async -> Void,
        timeoutSeconds: TimeInterval = 30
    ) {
        self.credentialStore = credentialStore
        self.runner = runner
        self.cliService = cliService
        self.healthRefresher = healthRefresher
        self.syncTrigger = syncTrigger
        self.timeoutSeconds = timeoutSeconds
    }

    func loginWithSavedToken(triggerSync: Bool = true) async -> PassCLIPATLoginResult {
        do {
            guard let token = try await credentialStore.loadToken(), token.isEmpty == false else {
                return .missingToken
            }
            let sanitizer = PassCLIPATOutputSanitizer(token: token)
            do {
                _ = try await runner.run(
                    executablePath: cliService.cliPath,
                    arguments: ["login"],
                    environmentOverrides: ["PROTON_PASS_PERSONAL_ACCESS_TOKEN": token],
                    timeout: timeoutSeconds
                )
            } catch CLIError.notInstalled {
                return .notInstalled
            } catch CLIError.timeout {
                return .timeout
            } catch let error as CLIError {
                let message = error.localizedDescription
                if sanitizer.isInvalidExpiredOrDeletedPAT(message) {
                    return .invalidToken
                }
                return .failed(sanitizer.sanitize(message))
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
}
