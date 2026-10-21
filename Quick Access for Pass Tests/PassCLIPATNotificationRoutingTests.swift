import Foundation
import os
import Security
import Testing
@testable import Quick_Access_for_Pass

@MainActor
private final class PATRoutingPoster: PassCLILoginNotificationPosting {
    var loggedOutCount = 0
    var resultTitles: [String] = []

    func postLoggedOutNotification() { loggedOutCount += 1 }
    func postResultNotification(title: String, body: String, categoryIdentifier: String?) {
        resultTitles.append(title)
    }
}

@MainActor
struct PassCLIPATNotificationRoutingTests {
    @Test(.timeLimit(.minutes(1)))
    func settingsRetainsLastKnownTokenStateWhileKeychainIsUnavailable() async {
        let status = OSAllocatedUnfairLock(initialState: errSecSuccess)
        let store = KeychainPassCLIPATCredentialStore(presenceQuery: { _ in status.withLock { $0 } })
        let model = PassCLIPATSettingsModel(
            sessionMutationGate: PassCLISessionMutationGate(), credentialStore: store,
            loginWithSavedToken: { _ in .succeeded }
        )
        await model.refreshSavedTokenState()
        #expect(model.hasSavedToken)
        status.withLock { $0 = errSecInteractionNotAllowed }
        await model.refreshSavedTokenState()
        #expect(model.hasSavedToken)
        status.withLock { $0 = errSecItemNotFound }
        await model.refreshSavedTokenState()
        #expect(!model.hasSavedToken)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [errSecInteractionNotAllowed, errSecNotAvailable, errSecAuthFailed, errSecDecode])
    func inaccessibleKeychainDoesNotMeanMissingPAT(status: OSStatus) async {
        let store = KeychainPassCLIPATCredentialStore(presenceQuery: { _ in status })

        await #expect(throws: KeychainError.self) {
            try await store.hasToken()
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [PassCLIHealth.notLoggedIn, .localSessionUnreadable])
    func unavailableKeychainDefersWithoutConsumingAttempt(health: PassCLIHealth) async {
        let status = OSAllocatedUnfairLock(initialState: errSecInteractionNotAllowed)
        let store = KeychainPassCLIPATCredentialStore(presenceQuery: { _ in status.withLock { $0 } })
        let poster = PATRoutingPoster()
        let notifier = PassCLILoginNotifier(notificationRouter: nil, poster: poster, startLogin: {})
        let gate = PassCLISessionMutationGate()
        var attempts = 0
        var started = 0
        let coordinator = PassCLIPATAutoLoginCoordinator(
            credentialStore: store, sessionMutationGate: gate, currentHealth: { health },
            loginWithSavedToken: { _ in attempts += 1; return .succeeded },
            fallbackHandler: notifier, patFailureHandler: { notifier.handlePATLoginFailure($0) },
            autoLoginStartedHandler: { started += 1 }
        )

        coordinator.handleCLIHealthTransition(to: health)
        await coordinator.waitForCurrentAttempt()
        #expect(!gate.isBusy)
        #expect(attempts == 0)
        #expect(started == 0)
        #expect(poster.loggedOutCount == 0)
        #expect(poster.resultTitles.isEmpty)

        status.withLock { $0 = errSecSuccess }
        coordinator.handleCLIHealthTransition(to: health)
        await coordinator.waitForCurrentAttempt()
        coordinator.handleCLIHealthTransition(to: health)
        await coordinator.waitForCurrentAttempt()
        #expect(attempts == 1)
        #expect(started == 1)
        #expect(!gate.isBusy)
        #expect(poster.loggedOutCount == 0)
        #expect(poster.resultTitles.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [PassCLIHealth.notLoggedIn, .localSessionUnreadable])
    func confirmedMissingPATStillRequestsSignIn(health: PassCLIHealth) async {
        let store = KeychainPassCLIPATCredentialStore(presenceQuery: { query in
            let attributes = query as NSDictionary
            #expect(attributes[kSecUseDataProtectionKeychain as String] as? Bool == true)
            #expect(attributes[kSecReturnData as String] == nil)
            return errSecItemNotFound
        })
        let poster = PATRoutingPoster()
        let notifier = PassCLILoginNotifier(notificationRouter: nil, poster: poster, startLogin: {})
        var attempts = 0
        let coordinator = PassCLIPATAutoLoginCoordinator(
            credentialStore: store, sessionMutationGate: PassCLISessionMutationGate(), currentHealth: { health },
            loginWithSavedToken: { _ in attempts += 1; return .succeeded },
            fallbackHandler: notifier, patFailureHandler: { notifier.handlePATLoginFailure($0) }
        )

        coordinator.handleCLIHealthTransition(to: health)
        await coordinator.waitForCurrentAttempt()
        coordinator.handleCLIHealthTransition(to: health)
        await coordinator.waitForCurrentAttempt()
        #expect(attempts == 0)
        #expect(poster.loggedOutCount == 1)
        #expect(poster.resultTitles.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [
        PassCLIPATLoginResult.timeout,
        .failed("Synthetic connection failure"),
        .healthStillNotOK("Synthetic unhealthy CLI")
    ], [PassCLIHealth.notLoggedIn, .localSessionUnreadable])
    func savedPATFailureDoesNotRequestBrowserSignIn(result: PassCLIPATLoginResult, health: PassCLIHealth) async throws {
        let store = OwnershipCredentials()
        let poster = PATRoutingPoster()
        let notifier = PassCLILoginNotifier(notificationRouter: nil, poster: poster, startLogin: {})
        var attempts = 0
        let coordinator = PassCLIPATAutoLoginCoordinator(
            credentialStore: store, sessionMutationGate: PassCLISessionMutationGate(), currentHealth: { health },
            loginWithSavedToken: { _ in attempts += 1; return result },
            fallbackHandler: notifier, patFailureHandler: { notifier.handlePATLoginFailure($0) }
        )

        coordinator.handleCLIHealthTransition(to: health)
        await coordinator.waitForCurrentAttempt()
        coordinator.handleCLIHealthTransition(to: health)
        await coordinator.waitForCurrentAttempt()

        #expect(poster.loggedOutCount == 0)
        #expect(poster.resultTitles == [String(localized: "Personal access token login failed")])
        #expect(attempts == 1)
        #expect(try await store.loadToken() == "synthetic-saved-pat")
    }
}
