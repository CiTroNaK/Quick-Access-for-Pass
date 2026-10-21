import Foundation
import Testing
@testable import Quick_Access_for_Pass

actor OwnershipPause {
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

actor OwnershipCredentials: PassCLIPATCredentialStoring {
    private var token: String? = "synthetic-saved-pat"
    private let lookupPause: OwnershipPause?
    private let presencePause: OwnershipPause?
    var lookupChecks = 0
    var presenceChecks = 0

    init(lookupPause: OwnershipPause? = nil, presencePause: OwnershipPause? = nil) {
        self.lookupPause = lookupPause
        self.presencePause = presencePause
    }
    func loadToken() async throws -> String? {
        lookupChecks += 1
        if lookupChecks == 1 { await lookupPause?.suspend() }
        return token
    }
    func hasToken() async -> Bool {
        presenceChecks += 1
        if presenceChecks == 1 { await presencePause?.suspend() }
        return token != nil
    }
    func saveToken(_ token: String) async throws { self.token = token }
    func deleteToken() async throws { token = nil }
}

actor OwnershipNativeRunner: CLIRunning, CLIEnvironmentRunning {
    struct Invocation: Sendable {
        let path: String
        let arguments: [String]
    }
    var invocations: [Invocation] = []
    private let firstCallPause: OwnershipPause?

    init(firstCallPause: OwnershipPause? = nil) { self.firstCallPause = firstCallPause }
    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        try await run(executablePath: executablePath, arguments: arguments, environmentOverrides: [:], timeout: timeout)
    }
    func run(
        executablePath: String, arguments: [String], environmentOverrides: [String: String], timeout: TimeInterval
    ) async throws -> Data {
        invocations.append(Invocation(path: executablePath, arguments: arguments))
        if invocations.count == 1 { await firstCallPause?.suspend() }
        return Data()
    }
}

nonisolated struct OwnershipBrowserRunner: CLIStreaming {
    func start(executablePath: String, arguments: [String], capturePolicy: CLIOutputCapturePolicy) throws -> CLIStreamingProcess {
        throw CLIError.commandFailed("Synthetic browser runner finished")
    }
}

nonisolated struct OwnershipHealth: PassCLIHealthRefreshing {
    func refreshPassCLIHealth() async -> PassCLIHealth { .ok }
}

@MainActor
struct PassCLIAuthenticationOwnershipTests {
    private let gate = PassCLISessionMutationGate()

    private func makePAT(
        cliService: PassCLIService, credentials: OwnershipCredentials, runner: OwnershipNativeRunner
    ) -> PassCLIPATLoginService {
        PassCLIPATLoginService(
            sessionMutationGate: gate,
            credentialStore: credentials, runner: runner, cliService: cliService,
            healthRefresher: OwnershipHealth(), syncTrigger: {}
        )
    }

    private func makeBrowser(cliService: PassCLIService, runner: OwnershipNativeRunner) -> PassCLILoginCoordinator {
        PassCLILoginCoordinator(
            sessionMutationGate: gate,
            cliService: cliService, currentHealth: { .localSessionUnreadable },
            runner: OwnershipBrowserRunner(), sessionResetRunner: runner,
            healthRefresher: OwnershipHealth(), syncTrigger: {}, resultHandler: { _ in }
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func browserRepairDoesNotOverlapPendingPATLookup() async {
        let cli = PassCLIService(cliPath: "/synthetic/pass-cli")
        let pause = OwnershipPause()
        let patRunner = OwnershipNativeRunner()
        let browserRunner = OwnershipNativeRunner()
        let pat = makePAT(cliService: cli, credentials: OwnershipCredentials(lookupPause: pause), runner: patRunner)
        let browser = makeBrowser(cliService: cli, runner: browserRunner)
        let first = Task { await pat.loginWithSavedToken() }
        await pause.waitUntilEntered()
        var confirmations = 0

        browser.requestLogin(confirmSessionReset: { confirmations += 1; return true })
        await browser.waitForCurrentLogin()
        #expect(confirmations == 0)
        #expect(await browserRunner.invocations.isEmpty)

        await pause.finish()
        #expect(await first.value == .succeeded)
    }

    @Test(.timeLimit(.minutes(1)))
    func browserRepairDoesNotOverlapPATLogin() async {
        let cli = PassCLIService(cliPath: "/synthetic/pass-cli")
        let pause = OwnershipPause()
        let patRunner = OwnershipNativeRunner(firstCallPause: pause)
        let browserRunner = OwnershipNativeRunner()
        let pat = makePAT(cliService: cli, credentials: OwnershipCredentials(), runner: patRunner)
        let browser = makeBrowser(cliService: cli, runner: browserRunner)
        let first = Task { await pat.loginWithSavedToken() }
        await pause.waitUntilEntered()
        var confirmations = 0

        browser.requestLogin(confirmSessionReset: { confirmations += 1; return true })
        await browser.waitForCurrentLogin()
        #expect(confirmations == 0)
        #expect(await browserRunner.invocations.isEmpty)

        await pause.finish()
        #expect(await first.value == .succeeded)
    }

    @Test(.timeLimit(.minutes(1)))
    func manualPATDoesNotOverlapBrowserCleanup() async {
        let cli = PassCLIService(cliPath: "/synthetic/pass-cli")
        let pause = OwnershipPause()
        let browserRunner = OwnershipNativeRunner(firstCallPause: pause)
        let patRunner = OwnershipNativeRunner()
        let browser = makeBrowser(cliService: cli, runner: browserRunner)
        let pat = makePAT(cliService: cli, credentials: OwnershipCredentials(), runner: patRunner)
        browser.requestLogin(confirmSessionReset: { true })
        await pause.waitUntilEntered()

        let result = await pat.loginWithSavedToken()
        #expect(result == .busy)
        #expect(await patRunner.invocations.isEmpty)
        await pause.finish()
        await browser.waitForCurrentLogin()
    }

    @Test(.timeLimit(.minutes(1)))
    func savingWhileBrowserCleanupDoesNotReplaceSavedPAT() async throws {
        let cli = PassCLIService(cliPath: "/synthetic/pass-cli")
        let pause = OwnershipPause()
        let browserRunner = OwnershipNativeRunner(firstCallPause: pause)
        let credentials = OwnershipCredentials()
        let browser = makeBrowser(cliService: cli, runner: browserRunner)
        var loginCount = 0
        let model = PassCLIPATSettingsModel(
            sessionMutationGate: gate,
            credentialStore: credentials,
            loginWithSavedToken: { _ in loginCount += 1; return .succeeded }
        )
        browser.requestLogin(confirmSessionReset: { true })
        await pause.waitUntilEntered()

        await model.saveAndLogin(token: "synthetic-replacement-pat")
        #expect(try await credentials.loadToken() == "synthetic-saved-pat")
        #expect(loginCount == 0)
        await pause.finish()
        await browser.waitForCurrentLogin()
    }

    @Test(.timeLimit(.minutes(1)))
    func removalWhileBrowserCleanupDoesNotDeleteSavedPAT() async {
        let cli = PassCLIService(cliPath: "/synthetic/pass-cli")
        let pause = OwnershipPause()
        let browserRunner = OwnershipNativeRunner(firstCallPause: pause)
        let credentials = OwnershipCredentials()
        let browser = makeBrowser(cliService: cli, runner: browserRunner)
        let model = PassCLIPATSettingsModel(
            sessionMutationGate: gate,
            credentialStore: credentials, loginWithSavedToken: { _ in .succeeded },
            isCurrentSessionPersonalAccessToken: { true }, logoutFromPassCLI: { _ in }
        )
        browser.requestLogin(confirmSessionReset: { true })
        await pause.waitUntilEntered()

        await model.removeToken()
        #expect(await credentials.hasToken())
        await pause.finish()
        await browser.waitForCurrentLogin()
    }
}
