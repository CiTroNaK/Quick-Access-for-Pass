import Testing
@testable import Quick_Access_for_Pass

private actor FakePATSettingsCredentialStore: PassCLIPATCredentialStoring {
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
private final class FakePATLoginAction {
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
private final class FakePATInvalidRecorder {
    var messages: [String] = []

    func record(_ message: String) {
        messages.append(message)
    }
}

@MainActor
private final class FakePATLogoutAction {
    var callCount = 0

    func logout() async throws {
        callCount += 1
    }
}

@MainActor
struct PassCLIPATSettingsModelTests {
    @Test(.timeLimit(.minutes(1)))
    func refreshReadsSavedTokenStateWithoutLoadingTokenIntoViewState() async {
        let store = FakePATSettingsCredentialStore(token: "pst_test_token::secret")
        let login = FakePATLoginAction(results: [.succeeded])
        let model = PassCLIPATSettingsModel(
            credentialStore: store,
            loginWithSavedToken: { await login.login() }
        )

        await model.refreshSavedTokenState()

        #expect(model.hasSavedToken == true)
        #expect(model.errorMessage == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func saveAndLoginStoresTokenClearsInputAndReportsSuccess() async throws {
        let store = FakePATSettingsCredentialStore(token: nil)
        let login = FakePATLoginAction(results: [.succeeded])
        let model = PassCLIPATSettingsModel(
            credentialStore: store,
            loginWithSavedToken: { await login.login() }
        )

        await model.saveAndLogin(token: " pst_test_token::secret \n")

        #expect(try await store.loadToken() == "pst_test_token::secret")
        #expect(model.hasSavedToken == true)
        #expect(model.statusMessage == "Personal access token saved and Pass CLI connected.")
        #expect(model.errorMessage == nil)
        #expect(login.callCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func failedSaveAndLoginKeepsTokenAndShowsError() async throws {
        let store = FakePATSettingsCredentialStore(token: nil)
        let login = FakePATLoginAction(results: [.failed("invalid token")])
        let model = PassCLIPATSettingsModel(
            credentialStore: store,
            loginWithSavedToken: { await login.login() }
        )

        await model.saveAndLogin(token: "pst_test_token::secret")

        #expect(try await store.loadToken() == "pst_test_token::secret")
        #expect(model.hasSavedToken == true)
        #expect(model.errorMessage == "invalid token")
    }

    @Test(.timeLimit(.minutes(1)))
    func loginUsingSavedTokenReportsSuccess() async {
        let store = FakePATSettingsCredentialStore(token: "pst_test_token::secret")
        let login = FakePATLoginAction(results: [.succeeded])
        let model = PassCLIPATSettingsModel(
            credentialStore: store,
            loginWithSavedToken: { await login.login() }
        )
        model.hasSavedToken = true

        await model.loginUsingSavedToken()

        #expect(login.callCount == 1)
        #expect(model.hasSavedToken == true)
        #expect(model.statusMessage == "Pass CLI connected with saved personal access token.")
        #expect(model.errorMessage == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func loginUsingSavedTokenReportsInvalidPATToAppRecovery() async {
        let store = FakePATSettingsCredentialStore(token: "pst_test_token::secret")
        let login = FakePATLoginAction(results: [.invalidToken])
        let invalidPAT = FakePATInvalidRecorder()
        let model = PassCLIPATSettingsModel(
            credentialStore: store,
            loginWithSavedToken: { await login.login() },
            invalidPATHandler: { invalidPAT.record($0) }
        )
        model.hasSavedToken = true

        await model.loginUsingSavedToken()

        #expect(login.callCount == 1)
        #expect(model.hasSavedToken == true)
        #expect(model.statusMessage == nil)
        #expect(model.errorMessage == PassCLIPATLoginResult.invalidToken.userFacingMessage)
        #expect(invalidPAT.messages == [PassCLIPATLoginResult.invalidToken.userFacingMessage])
    }

    @Test(.timeLimit(.minutes(1)))
    func loginUsingSavedTokenClearsSavedStateWhenTokenIsMissing() async {
        let store = FakePATSettingsCredentialStore(token: nil)
        let login = FakePATLoginAction(results: [.missingToken])
        let model = PassCLIPATSettingsModel(
            credentialStore: store,
            loginWithSavedToken: { await login.login() }
        )
        model.hasSavedToken = true

        await model.loginUsingSavedToken()

        #expect(login.callCount == 1)
        #expect(model.hasSavedToken == false)
        #expect(model.statusMessage == nil)
        #expect(model.errorMessage == "No personal access token is saved.")
    }

    @Test(.timeLimit(.minutes(1)))
    func removeDeletesTokenLogsOutWhenCurrentSessionUsesPAT() async {
        let store = FakePATSettingsCredentialStore(token: "pst_test_token::secret")
        let login = FakePATLoginAction(results: [.succeeded])
        let logout = FakePATLogoutAction()
        let model = PassCLIPATSettingsModel(
            credentialStore: store,
            loginWithSavedToken: { await login.login() },
            isCurrentSessionPersonalAccessToken: { true },
            logoutFromPassCLI: { try await logout.logout() }
        )

        await model.removeToken()

        #expect(await store.hasToken() == false)
        #expect(logout.callCount == 1)
        #expect(model.hasSavedToken == false)
        #expect(model.statusMessage == "Personal access token removed.")
    }

    @Test(.timeLimit(.minutes(1)))
    func removeDeletesTokenWithoutLoggingOutNormalSession() async {
        let store = FakePATSettingsCredentialStore(token: "pst_test_token::secret")
        let login = FakePATLoginAction(results: [.succeeded])
        let logout = FakePATLogoutAction()
        let model = PassCLIPATSettingsModel(
            credentialStore: store,
            loginWithSavedToken: { await login.login() },
            isCurrentSessionPersonalAccessToken: { false },
            logoutFromPassCLI: { try await logout.logout() }
        )

        await model.removeToken()

        #expect(await store.hasToken() == false)
        #expect(logout.callCount == 0)
        #expect(model.hasSavedToken == false)
        #expect(model.statusMessage == "Personal access token removed.")
    }
}
