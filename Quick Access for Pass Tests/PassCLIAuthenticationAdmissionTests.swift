import Foundation
import Testing
@testable import Quick_Access_for_Pass

@MainActor
private final class AdmissionHealth: PassCLIHealthTransitionHandling {
    var health: PassCLIHealth = .notLoggedIn
    var transitions: [PassCLIHealth] = []
    var failures: [String] = []
    func handleCLIHealthTransition(to health: PassCLIHealth) { transitions.append(health) }
}

@MainActor
struct PassCLIAuthenticationAdmissionTests {
    private let gate = PassCLISessionMutationGate()
    private let cli = PassCLIService(cliPath: "/synthetic/pass-cli")

    private func pat(_ credentials: OwnershipCredentials, _ runner: OwnershipNativeRunner) -> PassCLIPATLoginService {
        PassCLIPATLoginService(
            sessionMutationGate: gate, credentialStore: credentials, runner: runner,
            cliService: cli, healthRefresher: OwnershipHealth(), syncTrigger: {}
        )
    }

    private func browser(_ runner: OwnershipNativeRunner) -> PassCLILoginCoordinator {
        PassCLILoginCoordinator(
            sessionMutationGate: gate, cliService: cli, currentHealth: { .localSessionUnreadable },
            runner: OwnershipBrowserRunner(),
            sessionResetRunner: runner, healthRefresher: OwnershipHealth(), syncTrigger: {}, resultHandler: { _ in }
        )
    }

    private func automatic(_ credentials: OwnershipCredentials, _ service: PassCLIPATLoginService, _ state: AdmissionHealth)
        -> PassCLIPATAutoLoginCoordinator {
        PassCLIPATAutoLoginCoordinator(
            credentialStore: credentials, sessionMutationGate: gate, currentHealth: { state.health },
            loginWithSavedToken: { lease in await service.loginWithSavedToken(triggerSync: false, lease: lease) },
            fallbackHandler: state, patFailureHandler: { state.failures.append($0) }
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func automaticOwnsAdmissionDuringTokenPresenceLookup() async {
        let pause = OwnershipPause()
        let credentials = OwnershipCredentials(presencePause: pause)
        let native = OwnershipNativeRunner()
        let state = AdmissionHealth()
        let auto = automatic(credentials, pat(credentials, native), state)
        let reset = OwnershipNativeRunner()
        let browser = browser(reset)
        auto.handleCLIHealthTransition(to: .notLoggedIn)
        await pause.waitUntilEntered()
        var confirmations = 0

        browser.requestLogin(confirmSessionReset: { confirmations += 1; return true })
        await browser.waitForCurrentLogin()
        #expect(confirmations == 0)
        #expect(await reset.invocations.isEmpty)
        await pause.finish()
        await auto.waitForCurrentAttempt()
        #expect(await native.invocations.count == 1)
        #expect(!gate.isBusy)
    }

    @Test(.timeLimit(.minutes(1)))
    func automaticBusyDoesNotConsumeAttemptOrPublishFallback() async {
        let pause = OwnershipPause()
        let reset = OwnershipNativeRunner(firstCallPause: pause)
        let browser = browser(reset)
        let credentials = OwnershipCredentials()
        let native = OwnershipNativeRunner()
        let state = AdmissionHealth()
        let auto = automatic(credentials, pat(credentials, native), state)
        browser.requestLogin(confirmSessionReset: { true })
        await pause.waitUntilEntered()

        auto.handleCLIHealthTransition(to: .notLoggedIn)
        await auto.waitForCurrentAttempt()
        #expect(await credentials.presenceChecks == 0)
        #expect(state.transitions.isEmpty)
        #expect(state.failures.isEmpty)
        await pause.finish()
        await browser.waitForCurrentLogin()
        auto.handleCLIHealthTransition(to: .notLoggedIn)
        await auto.waitForCurrentAttempt()
        #expect(await native.invocations.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func automaticRevalidatesHealthAfterLookupWithoutConsumingAttempt() async {
        let pause = OwnershipPause()
        let credentials = OwnershipCredentials(presencePause: pause)
        let native = OwnershipNativeRunner()
        let state = AdmissionHealth()
        let auto = automatic(credentials, pat(credentials, native), state)
        auto.handleCLIHealthTransition(to: .notLoggedIn)
        await pause.waitUntilEntered()
        state.health = .ok
        await pause.finish()
        await auto.waitForCurrentAttempt()
        #expect(await native.invocations.isEmpty)
        #expect(state.transitions.isEmpty)
        #expect(state.failures.isEmpty)
        #expect(!gate.isBusy)

        state.health = .notLoggedIn
        auto.handleCLIHealthTransition(to: .notLoggedIn)
        await auto.waitForCurrentAttempt()
        #expect(await native.invocations.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledPATLookupRetainsOwnershipUntilUnwind() async {
        let pause = OwnershipPause()
        let native = OwnershipNativeRunner()
        let first = pat(OwnershipCredentials(lookupPause: pause), native)
        let second = pat(OwnershipCredentials(), native)
        let task = Task { await first.loginWithSavedToken() }
        await pause.waitUntilEntered()
        task.cancel()
        #expect(await second.loginWithSavedToken() == .busy)
        #expect(await native.invocations.isEmpty)
        await pause.finish()
        _ = await task.value
        #expect(!gate.isBusy)
        #expect(await second.loginWithSavedToken() == .succeeded)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledBrowserCleanupRetainsOwnershipUntilUnwind() async {
        let pause = OwnershipPause()
        let reset = OwnershipNativeRunner(firstCallPause: pause)
        let browser = browser(reset)
        let native = OwnershipNativeRunner()
        let service = pat(OwnershipCredentials(), native)
        browser.requestLogin(confirmSessionReset: { true })
        await pause.waitUntilEntered()
        browser.cancel()
        #expect(await service.loginWithSavedToken() == .busy)
        #expect(await native.invocations.isEmpty)
        await pause.finish()
        await browser.waitForCurrentLogin()
        #expect(!gate.isBusy)
        #expect(await service.loginWithSavedToken() == .succeeded)
    }

    @Test
    func borrowedLeaseMustMatchGateAndRoleAndRemainCallerOwned() async throws {
        let credentials = OwnershipCredentials()
        let service = pat(credentials, OwnershipNativeRunner())
        let otherGate = PassCLISessionMutationGate()
        let foreign = try #require(otherGate.tryAcquire(.savedTokenLogin))
        #expect(await service.loginWithSavedToken(lease: foreign) == .busy)
        #expect(otherGate.owns(foreign))
        otherGate.release(foreign)
        let wrongRole = try #require(gate.tryAcquire(.logout))
        #expect(await service.loginWithSavedToken(lease: wrongRole) == .busy)
        #expect(await credentials.lookupChecks == 0)
        #expect(gate.owns(wrongRole))
        gate.release(wrongRole)
        let valid = try #require(gate.tryAcquire(.savedTokenLogin))
        #expect(await service.loginWithSavedToken(lease: valid) == .succeeded)
        #expect(gate.owns(valid))
        gate.release(valid)
    }
}
