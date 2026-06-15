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

    func setOutcome(_ outcome: Outcome) {
        self.outcome = outcome
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
        switch outcome {
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
