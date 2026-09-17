import Foundation
import Testing
@testable import Quick_Access_for_Pass

private actor FakePATLoginCredentialStore: PassCLIPATCredentialStoring {
    var token: String?

    init(token: String? = nil) {
        self.token = token
    }

    func loadToken() async throws -> String? { token }
    func saveToken(_ token: String) async throws { self.token = token }
    func deleteToken() async throws { token = nil }
    func hasToken() async -> Bool { token != nil }
}

private actor FakeEnvironmentRunner: CLIEnvironmentRunning {
    struct Invocation: Sendable, Equatable {
        let executablePath: String
        let arguments: [String]
        let environmentOverrides: [String: String]
    }

    enum Outcome: Sendable {
        case success(Data)
        case failure(CLIError)
    }

    var invocations: [Invocation] = []
    private var outcome: Outcome = .success(Data())
    private var queuedOutcomes: [Outcome] = []
    private var pausesFirstInvocation = false
    private var firstInvocationWaiter: CheckedContinuation<Void, Never>?
    private var firstInvocationResume: CheckedContinuation<Void, Never>?

    func pauseFirstInvocation() {
        pausesFirstInvocation = true
    }

    func waitForFirstInvocation() async {
        guard invocations.isEmpty else { return }
        await withCheckedContinuation { firstInvocationWaiter = $0 }
    }

    func resumeFirstInvocation() {
        firstInvocationResume?.resume()
        firstInvocationResume = nil
    }

    func setOutcome(_ outcome: Outcome) {
        self.outcome = outcome
    }

    func setOutcomes(_ outcomes: [Outcome]) {
        queuedOutcomes = outcomes
    }

    func run(
        executablePath: String,
        arguments: [String],
        environmentOverrides: [String: String],
        timeout: TimeInterval
    ) async throws -> Data {
        invocations.append(Invocation(
            executablePath: executablePath,
            arguments: arguments,
            environmentOverrides: environmentOverrides
        ))
        let nextOutcome = queuedOutcomes.isEmpty ? outcome : queuedOutcomes.removeFirst()
        if pausesFirstInvocation && invocations.count == 1 {
            await withCheckedContinuation { continuation in
                firstInvocationResume = continuation
                firstInvocationWaiter?.resume()
                firstInvocationWaiter = nil
            }
        }
        switch nextOutcome {
        case .success(let data):
            return data
        case .failure(let error):
            throw error
        }
    }
}

private struct FakePATHealthRefresher: PassCLIHealthRefreshing {
    let health: PassCLIHealth

    nonisolated func refreshPassCLIHealth() async -> PassCLIHealth {
        health
    }
}

private actor PATSyncRecorder {
    private var value = 0
    func increment() { value += 1 }
    func count() -> Int { value }
}

@MainActor
struct PassCLIPATLoginServiceTests {
    @Test(.timeLimit(.minutes(1)))
    func loginWithSavedTokenPassesTokenAsEnvironmentVariableAndSyncsWhenHealthy() async throws {
        let store = FakePATLoginCredentialStore(token: "pst_test_token::secret")
        let runner = FakeEnvironmentRunner()
        let sync = PATSyncRecorder()
        let service = PassCLIPATLoginService(
            credentialStore: store,
            runner: runner,
            cliService: PassCLIService(cliPath: "/fake/pass-cli"),
            healthRefresher: FakePATHealthRefresher(health: .ok),
            syncTrigger: { await sync.increment() }
        )

        let result = await service.loginWithSavedToken()

        #expect(result == .succeeded)
        let invocation = try #require(await runner.invocations.first)
        #expect(invocation.executablePath == "/fake/pass-cli")
        #expect(invocation.arguments == ["login"])
        #expect(invocation.environmentOverrides["PROTON_PASS_PERSONAL_ACCESS_TOKEN"] == "pst_test_token::secret")
        #expect(await sync.count() == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func overlappingLoginDoesNotStartAnotherSessionMutation() async {
        let runner = FakeEnvironmentRunner()
        await runner.pauseFirstInvocation()
        let service = PassCLIPATLoginService(
            credentialStore: FakePATLoginCredentialStore(token: "pst_test_token::secret"),
            runner: runner,
            cliService: PassCLIService(cliPath: "/fake/pass-cli"),
            healthRefresher: FakePATHealthRefresher(health: .ok),
            syncTrigger: {}
        )
        let first = Task { await service.loginWithSavedToken() }
        await runner.waitForFirstInvocation()

        let second = await service.loginWithSavedToken()

        #expect(second != .succeeded)
        #expect(await runner.invocations.count == 1)
        await runner.resumeFirstInvocation()
        #expect(await first.value == .succeeded)
        // The guard must be released after completion, not block future logins.
        #expect(await service.loginWithSavedToken() == .succeeded)
        #expect(await runner.invocations.count == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func alreadyAuthenticatedWithMissingRemoteSessionRecoversAndSyncs() async {
        let token = "pst_test_token::secret"
        let runner = FakeEnvironmentRunner()
        await runner.setOutcomes([
            .failure(.commandFailed("Error: Already authenticated")),
            .failure(.commandFailed("Error getting personal access token name: failed to authenticate: non-existent session")),
            .success(Data()),
            .success(Data()),
        ])
        let sync = PATSyncRecorder()
        let service = PassCLIPATLoginService(
            credentialStore: FakePATLoginCredentialStore(token: token),
            runner: runner,
            cliService: PassCLIService(cliPath: "/fake/pass-cli"),
            healthRefresher: FakePATHealthRefresher(health: .ok),
            syncTrigger: { await sync.increment() }
        )

        let result = await service.loginWithSavedToken()

        #expect(result == .succeeded)
        #expect(await sync.count() == 1)
        let invocations = await runner.invocations
        #expect(invocations.map(\.arguments) == [["login"], ["info", "--output", "json"], ["logout", "--force"], ["login"]])
        #expect(invocations.allSatisfy { $0.executablePath == "/fake/pass-cli" })
        for invocation in invocations {
            let expectedEnvironment = invocation.arguments == ["login"]
                ? ["PROTON_PASS_PERSONAL_ACCESS_TOKEN": token] : [:]
            #expect(invocation.environmentOverrides == expectedEnvironment)
            #expect(invocation.arguments.contains(token) == false)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [
        FakeEnvironmentRunner.Outcome.success(Data()),
        .failure(.timeout),
        .failure(.commandFailed("network unreachable")),
        .failure(.notInstalled),
    ])
    private func alreadyAuthenticatedDoesNotClearHealthyOrUncertainSession(probeOutcome: FakeEnvironmentRunner.Outcome) async {
        let runner = FakeEnvironmentRunner()
        await runner.setOutcomes([
            .failure(.commandFailed("Error: Already authenticated")),
            probeOutcome,
        ])
        let sync = PATSyncRecorder()
        let service = PassCLIPATLoginService(
            credentialStore: FakePATLoginCredentialStore(token: "pst_test_token::secret"),
            runner: runner,
            cliService: PassCLIService(cliPath: "/fake/pass-cli"),
            healthRefresher: FakePATHealthRefresher(health: .ok),
            syncTrigger: { await sync.increment() }
        )

        let result = await service.loginWithSavedToken()

        #expect(result != .succeeded)
        #expect(await sync.count() == 0)
        #expect(await runner.invocations.map(\.arguments) == [["login"], ["info", "--output", "json"]])
    }

    @Test(.timeLimit(.minutes(1)))
    func failedRecoveryLogoutStopsBeforeRetryAndRedactsToken() async {
        let token = "pst_test_token::secret"
        let runner = FakeEnvironmentRunner()
        await runner.setOutcomes([
            .failure(.commandFailed("Error: Already authenticated")),
            .failure(.notLoggedIn),
            .failure(.commandFailed("cleanup failed \(token)")),
        ])
        let sync = PATSyncRecorder()
        let service = PassCLIPATLoginService(
            credentialStore: FakePATLoginCredentialStore(token: token),
            runner: runner,
            cliService: PassCLIService(cliPath: "/fake/pass-cli"),
            healthRefresher: FakePATHealthRefresher(health: .ok),
            syncTrigger: { await sync.increment() }
        )

        let result = await service.loginWithSavedToken()

        guard case .failed(let message) = result else {
            Issue.record("Expected cleanup failure")
            return
        }
        #expect(message.contains("cleanup failed"))
        #expect(message.contains(token) == false)
        #expect(await sync.count() == 0)
        #expect(await runner.invocations.map(\.arguments) == [["login"], ["info", "--output", "json"], ["logout", "--force"]])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func recoveryRetriesLoginOnlyOnce(invalidToken: Bool) async {
        let runner = FakeEnvironmentRunner()
        let retryError = invalidToken
            ? "This personal access token is invalid, expired or has been deleted."
            : "Error: Already authenticated"
        await runner.setOutcomes([
            .failure(.commandFailed("Error: Already authenticated")),
            .failure(.notLoggedIn),
            .success(Data()),
            .failure(.commandFailed(retryError)),
        ])
        let sync = PATSyncRecorder()
        let service = PassCLIPATLoginService(
            credentialStore: FakePATLoginCredentialStore(token: "pst_test_token::secret"),
            runner: runner,
            cliService: PassCLIService(cliPath: "/fake/pass-cli"),
            healthRefresher: FakePATHealthRefresher(health: .ok),
            syncTrigger: { await sync.increment() }
        )

        let result = await service.loginWithSavedToken()

        if invalidToken {
            #expect(result == .invalidToken)
        } else {
            #expect(result != .succeeded)
        }
        #expect(await sync.count() == 0)
        #expect(await runner.invocations.map(\.arguments) == [["login"], ["info", "--output", "json"], ["logout", "--force"], ["login"]])
    }

    @Test(.timeLimit(.minutes(1)))
    func missingTokenReturnsMissingTokenAndDoesNotRunCLI() async {
        let store = FakePATLoginCredentialStore(token: nil)
        let runner = FakeEnvironmentRunner()
        let service = PassCLIPATLoginService(
            credentialStore: store,
            runner: runner,
            cliService: PassCLIService(cliPath: "/fake/pass-cli"),
            healthRefresher: FakePATHealthRefresher(health: .ok),
            syncTrigger: {}
        )

        let result = await service.loginWithSavedToken()

        #expect(result == .missingToken)
        #expect(await runner.invocations.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func failedLoginRedactsExactTokenAndEnvironmentAssignment() async {
        let token = "pst_test_token::secret"
        let store = FakePATLoginCredentialStore(token: token)
        let runner = FakeEnvironmentRunner()
        await runner.setOutcome(.failure(CLIError.commandFailed("bad token \(token) PROTON_PASS_PERSONAL_ACCESS_TOKEN=\(token)")))
        let service = PassCLIPATLoginService(
            credentialStore: store,
            runner: runner,
            cliService: PassCLIService(cliPath: "/fake/pass-cli"),
            healthRefresher: FakePATHealthRefresher(health: .notLoggedIn),
            syncTrigger: {}
        )

        let result = await service.loginWithSavedToken()

        guard case .failed(let message) = result else {
            Issue.record("Expected failed result")
            return
        }
        #expect(message.contains(token) == false)
        #expect(message.contains("PROTON_PASS_PERSONAL_ACCESS_TOKEN=") == false)
        #expect(message.contains("[PAT redacted]") == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func invalidExpiredOrDeletedPATReturnsSpecificResult() async {
        let token = "pst_test_token::secret"
        let store = FakePATLoginCredentialStore(token: token)
        let runner = FakeEnvironmentRunner()
        let error = """
        Error: Error in personal access token login flow

        Caused by:
            0: Error creating personal access token session
            1: This personal access token is invalid, expired or has been deleted.
        """
        await runner.setOutcome(.failure(CLIError.commandFailed(error)))
        let service = PassCLIPATLoginService(
            credentialStore: store,
            runner: runner,
            cliService: PassCLIService(cliPath: "/fake/pass-cli"),
            healthRefresher: FakePATHealthRefresher(health: .notLoggedIn),
            syncTrigger: {}
        )

        let result = await service.loginWithSavedToken()

        #expect(result == .invalidToken)
        #expect(result.userFacingMessage.contains("invalid, expired, or deleted"))
        #expect(result.userFacingMessage.contains(token) == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func commandSuccessButUnhealthyRefreshReturnsHealthStillNotOK() async {
        let store = FakePATLoginCredentialStore(token: "pst_test_token::secret")
        let runner = FakeEnvironmentRunner()
        let service = PassCLIPATLoginService(
            credentialStore: store,
            runner: runner,
            cliService: PassCLIService(cliPath: "/fake/pass-cli"),
            healthRefresher: FakePATHealthRefresher(health: .notLoggedIn),
            syncTrigger: {}
        )

        let result = await service.loginWithSavedToken()

        guard case .healthStillNotOK(let message) = result else {
            Issue.record("Expected healthStillNotOK result")
            return
        }
        #expect(message.contains("still not connected"))
    }
}
