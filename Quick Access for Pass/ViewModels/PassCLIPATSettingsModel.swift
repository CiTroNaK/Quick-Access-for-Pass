import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class PassCLIPATSettingsModel {
    private let credentialStore: any PassCLIPATCredentialStoring
    private let sessionMutationGate: PassCLISessionMutationGate
    private let loginWithSavedToken: @MainActor @Sendable (PassCLISessionMutationGate.Lease) async -> PassCLIPATLoginResult
    private let invalidPATHandler: @MainActor @Sendable (String) -> Void
    private let isCurrentSessionPersonalAccessToken: @MainActor @Sendable () -> Bool
    private let logoutFromPassCLI: @MainActor @Sendable (PassCLISessionMutationGate.Lease) async throws -> Void

    var hasSavedToken = false
    var isLoggingIn = false
    var statusMessage: String?
    var errorMessage: String?

    init(
        sessionMutationGate: PassCLISessionMutationGate,
        credentialStore: any PassCLIPATCredentialStoring,
        loginWithSavedToken: @escaping @MainActor @Sendable (PassCLISessionMutationGate.Lease) async -> PassCLIPATLoginResult,
        invalidPATHandler: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        isCurrentSessionPersonalAccessToken: @escaping @MainActor @Sendable () -> Bool = { false },
        logoutFromPassCLI: @escaping @MainActor @Sendable (PassCLISessionMutationGate.Lease) async throws -> Void = { _ in }
    ) {
        self.sessionMutationGate = sessionMutationGate
        self.credentialStore = credentialStore
        self.loginWithSavedToken = loginWithSavedToken
        self.invalidPATHandler = invalidPATHandler
        self.isCurrentSessionPersonalAccessToken = isCurrentSessionPersonalAccessToken
        self.logoutFromPassCLI = logoutFromPassCLI
    }

    func refreshSavedTokenState() async {
        // Retain the last display state when Keychain is temporarily unavailable.
        if let hasToken = try? await credentialStore.hasToken() {
            hasSavedToken = hasToken
        }
    }

    func saveAndLogin(token: String) async {
        guard let lease = acquire(.savedTokenLogin) else { return }
        defer { sessionMutationGate.release(lease) }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            setError(String(localized: "Enter a personal access token."))
            return
        }

        isLoggingIn = true
        defer { isLoggingIn = false }

        do {
            try await credentialStore.saveToken(trimmed)
            hasSavedToken = true
            await runSavedTokenLogin(successMessage: String(localized: "Personal access token saved and Pass CLI connected."), lease: lease)
        } catch {
            setError(String(localized: "Could not save personal access token: \(error.localizedDescription)"))
        }
    }

    func loginUsingSavedToken() async {
        guard let lease = acquire(.savedTokenLogin) else { return }
        isLoggingIn = true
        defer {
            isLoggingIn = false
            sessionMutationGate.release(lease)
        }
        await runSavedTokenLogin(successMessage: String(localized: "Pass CLI connected with saved personal access token."), lease: lease)
    }

    func removeToken() async {
        guard let lease = acquire(.logout) else { return }
        defer { sessionMutationGate.release(lease) }
        do {
            try await credentialStore.deleteToken()
            hasSavedToken = false
            if isCurrentSessionPersonalAccessToken() {
                try await logoutFromPassCLI(lease)
            }
            setStatus(String(localized: "Personal access token removed."))
        } catch {
            setError(String(localized: "Could not remove personal access token: \(error.localizedDescription)"))
        }
    }

    private func acquire(_ operation: PassCLISessionMutationGate.Operation) -> PassCLISessionMutationGate.Lease? {
        guard let lease = sessionMutationGate.tryAcquire(operation) else {
            setStatus(PassCLIPATLoginResult.busy.userFacingMessage)
            return nil
        }
        return lease
    }

    private func runSavedTokenLogin(successMessage: String, lease: PassCLISessionMutationGate.Lease) async {
        let result = await loginWithSavedToken(lease)
        switch result {
        case .busy:
            setStatus(result.userFacingMessage)
        case .succeeded:
            setStatus(successMessage)
        case .missingToken:
            hasSavedToken = false
            setError(result.userFacingMessage)
        case .invalidToken:
            setError(result.userFacingMessage)
            invalidPATHandler(result.userFacingMessage)
        case .notInstalled, .timeout, .failed, .healthStillNotOK:
            setError(result.userFacingMessage)
        }
    }

    private func setStatus(_ message: String) {
        statusMessage = message
        errorMessage = nil
        announce(message)
    }

    private func setError(_ message: String) {
        statusMessage = nil
        errorMessage = message
        announce(message)
    }

    private func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }
}
