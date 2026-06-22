import Foundation
import Testing
@testable import Quick_Access_for_Pass

private actor FakePATAutoLoginCredentialStore: PassCLIPATCredentialStoring {
    var token: String?

    init(token: String? = nil) {
        self.token = token
    }

    func loadToken() async throws -> String? { token }
    func saveToken(_ token: String) async throws { self.token = token }
    func deleteToken() async throws { token = nil }
    func hasToken() async -> Bool { token != nil }
}

@MainActor
private final class FakeTransitionHandler: PassCLIHealthTransitionHandling {
    var transitions: [PassCLIHealth] = []
    func handleCLIHealthTransition(to health: PassCLIHealth) {
        transitions.append(health)
    }
}

@MainActor
private final class FakePATLoginRunner {
    var results: [PassCLIPATLoginResult]
    var callCount = 0

    init(results: [PassCLIPATLoginResult]) {
        self.results = results
    }

    func login() async -> PassCLIPATLoginResult {
        callCount += 1
        return results.isEmpty ? .failed("missing fake result") : results.removeFirst()
    }
}

@MainActor
private final class PATFailureRecorder {
    var messages: [String] = []
    func record(_ message: String) { messages.append(message) }
}

@MainActor
private final class PATAutoLoginStartedRecorder {
    var callCount = 0
    func record() { callCount += 1 }
}

@MainActor
private final class PATInvalidRecorder {
    var messages: [String] = []
    func record(_ message: String) { messages.append(message) }
}

@MainActor
struct PassCLIPATAutoLoginCoordinatorTests {
    @Test(.timeLimit(.minutes(1)))
    func loggedOutWithoutSavedPATFallsBackToNormalNotifier() async {
        let store = FakePATAutoLoginCredentialStore(token: nil)
        let fallback = FakeTransitionHandler()
        let runner = FakePATLoginRunner(results: [.succeeded])
        let failures = PATFailureRecorder()
        let coordinator = PassCLIPATAutoLoginCoordinator(
            credentialStore: store,
            loginWithSavedToken: { await runner.login() },
            fallbackHandler: fallback,
            patFailureHandler: { failures.record($0) },
            invalidPATHandler: { _ in },
            browserLoginIsRunning: { false }
        )

        coordinator.handleCLIHealthTransition(to: .notLoggedIn)
        await coordinator.waitForCurrentAttempt()

        #expect(runner.callCount == 0)
        #expect(fallback.transitions == [.notLoggedIn])
        #expect(failures.messages.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func loggedOutWithSavedPATReportsAutomaticLoginBeforeAttempt() async {
        let store = FakePATAutoLoginCredentialStore(token: "pst_test_token::secret")
        let fallback = FakeTransitionHandler()
        let runner = FakePATLoginRunner(results: [.succeeded])
        let failures = PATFailureRecorder()
        let autoLoginStarted = PATAutoLoginStartedRecorder()
        let coordinator = PassCLIPATAutoLoginCoordinator(
            credentialStore: store,
            loginWithSavedToken: { await runner.login() },
            fallbackHandler: fallback,
            patFailureHandler: { failures.record($0) },
            invalidPATHandler: { _ in },
            autoLoginStartedHandler: { autoLoginStarted.record() },
            browserLoginIsRunning: { false }
        )

        coordinator.handleCLIHealthTransition(to: .notLoggedIn)
        await coordinator.waitForCurrentAttempt()

        #expect(autoLoginStarted.callCount == 1)
        #expect(runner.callCount == 1)
        #expect(fallback.transitions.isEmpty)
        #expect(failures.messages.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func loggedOutWithSavedPATAttemptsLoginAndSuppressesFallbackOnSuccess() async {
        let store = FakePATAutoLoginCredentialStore(token: "pst_test_token::secret")
        let fallback = FakeTransitionHandler()
        let runner = FakePATLoginRunner(results: [.succeeded])
        let failures = PATFailureRecorder()
        let coordinator = PassCLIPATAutoLoginCoordinator(
            credentialStore: store,
            loginWithSavedToken: { await runner.login() },
            fallbackHandler: fallback,
            patFailureHandler: { failures.record($0) },
            invalidPATHandler: { _ in },
            browserLoginIsRunning: { false }
        )

        coordinator.handleCLIHealthTransition(to: .notLoggedIn)
        await coordinator.waitForCurrentAttempt()

        #expect(runner.callCount == 1)
        #expect(fallback.transitions.isEmpty)
        #expect(failures.messages.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func failedPATLoginWarnsFallsBackAndDoesNotDeleteToken() async throws {
        let store = FakePATAutoLoginCredentialStore(token: "pst_test_token::secret")
        let fallback = FakeTransitionHandler()
        let runner = FakePATLoginRunner(results: [.failed("invalid token")])
        let failures = PATFailureRecorder()
        let coordinator = PassCLIPATAutoLoginCoordinator(
            credentialStore: store,
            loginWithSavedToken: { await runner.login() },
            fallbackHandler: fallback,
            patFailureHandler: { failures.record($0) },
            invalidPATHandler: { _ in },
            browserLoginIsRunning: { false }
        )

        coordinator.handleCLIHealthTransition(to: .notLoggedIn)
        await coordinator.waitForCurrentAttempt()

        #expect(try await store.loadToken() == "pst_test_token::secret")
        #expect(failures.messages == ["invalid token"])
        #expect(fallback.transitions == [.notLoggedIn])
    }

    @Test(.timeLimit(.minutes(1)))
    func invalidPATLoginWarnsWithSpecificMessageAndShowsUpdatePAT() async throws {
        let store = FakePATAutoLoginCredentialStore(token: "pst_test_token::secret")
        let fallback = FakeTransitionHandler()
        let runner = FakePATLoginRunner(results: [.invalidToken])
        let failures = PATFailureRecorder()
        let invalidPAT = PATInvalidRecorder()
        let coordinator = PassCLIPATAutoLoginCoordinator(
            credentialStore: store,
            loginWithSavedToken: { await runner.login() },
            fallbackHandler: fallback,
            patFailureHandler: { failures.record($0) },
            invalidPATHandler: { invalidPAT.record($0) },
            browserLoginIsRunning: { false }
        )

        coordinator.handleCLIHealthTransition(to: .notLoggedIn)
        await coordinator.waitForCurrentAttempt()

        #expect(try await store.loadToken() == "pst_test_token::secret")
        #expect(failures.messages == [PassCLIPATLoginResult.invalidToken.userFacingMessage])
        #expect(invalidPAT.messages == [PassCLIPATLoginResult.invalidToken.userFacingMessage])
        #expect(fallback.transitions.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func automaticPATLoginRunsOncePerLoggedOutEpisodeAndResetsAfterOK() async {
        let store = FakePATAutoLoginCredentialStore(token: "pst_test_token::secret")
        let fallback = FakeTransitionHandler()
        let runner = FakePATLoginRunner(results: [.failed("first"), .succeeded])
        let failures = PATFailureRecorder()
        let coordinator = PassCLIPATAutoLoginCoordinator(
            credentialStore: store,
            loginWithSavedToken: { await runner.login() },
            fallbackHandler: fallback,
            patFailureHandler: { failures.record($0) },
            invalidPATHandler: { _ in },
            browserLoginIsRunning: { false }
        )

        coordinator.handleCLIHealthTransition(to: .notLoggedIn)
        await coordinator.waitForCurrentAttempt()
        coordinator.handleCLIHealthTransition(to: .notLoggedIn)
        await coordinator.waitForCurrentAttempt()
        coordinator.handleCLIHealthTransition(to: .ok)
        coordinator.handleCLIHealthTransition(to: .notLoggedIn)
        await coordinator.waitForCurrentAttempt()

        #expect(runner.callCount == 2)
        #expect(fallback.transitions == [.notLoggedIn, .ok])
    }
}
