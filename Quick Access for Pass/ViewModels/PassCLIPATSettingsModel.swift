import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class PassCLIPATSettingsModel {
    private let credentialStore: any PassCLIPATCredentialStoring
    private let loginWithSavedToken: @MainActor @Sendable () async -> PassCLIPATLoginResult
    private let invalidPATHandler: @MainActor @Sendable (String) -> Void
    private let isCurrentSessionPersonalAccessToken: @MainActor @Sendable () -> Bool
    private let logoutFromPassCLI: @MainActor @Sendable () async throws -> Void

    var hasSavedToken = false
    var isLoggingIn = false
    var statusMessage: String?
    var errorMessage: String?

    init(
        credentialStore: any PassCLIPATCredentialStoring,
        loginWithSavedToken: @escaping @MainActor @Sendable () async -> PassCLIPATLoginResult,
        invalidPATHandler: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        isCurrentSessionPersonalAccessToken: @escaping @MainActor @Sendable () -> Bool = { false },
        logoutFromPassCLI: @escaping @MainActor @Sendable () async throws -> Void = {}
    ) {
        self.credentialStore = credentialStore
        self.loginWithSavedToken = loginWithSavedToken
        self.invalidPATHandler = invalidPATHandler
        self.isCurrentSessionPersonalAccessToken = isCurrentSessionPersonalAccessToken
        self.logoutFromPassCLI = logoutFromPassCLI
    }

    func refreshSavedTokenState() async {
        hasSavedToken = await credentialStore.hasToken()
    }

    func saveAndLogin(token: String) async {
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
            await runSavedTokenLogin(successMessage: String(localized: "Personal access token saved and Pass CLI connected."))
        } catch {
            setError(String(localized: "Could not save personal access token: \(error.localizedDescription)"))
        }
    }

    func loginUsingSavedToken() async {
        isLoggingIn = true
        defer { isLoggingIn = false }
        await runSavedTokenLogin(successMessage: String(localized: "Pass CLI connected with saved personal access token."))
    }

    func removeToken() async {
        do {
            try await credentialStore.deleteToken()
            if isCurrentSessionPersonalAccessToken() {
                try await logoutFromPassCLI()
            }
            hasSavedToken = false
            setStatus(String(localized: "Personal access token removed."))
        } catch {
            setError(String(localized: "Could not remove personal access token: \(error.localizedDescription)"))
        }
    }

    private func runSavedTokenLogin(successMessage: String) async {
        let result = await loginWithSavedToken()
        switch result {
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
