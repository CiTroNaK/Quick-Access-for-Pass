import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("SyncCoordinator sync issue notifications")
@MainActor
struct SyncCoordinatorSyncIssueTests {
    @Test("auth errors resolve diagnostics window")
    func authErrorsResolveDiagnosticsWindow() async throws {
        let harness = try makeHarness(error: CLIError.notLoggedIn)
        var updates: [QuickAccessSyncIssuePresentation?] = []
        let coordinator = SyncCoordinator(
            cliService: harness.cliService,
            databaseManager: harness.databaseManager,
            viewModel: harness.viewModel,
            onSyncIssueChanged: { presentation in
                updates.append(presentation)
            }
        )

        coordinator.refreshNow()
        await waitForUpdateCount(1) { updates.count }

        #expect(harness.viewModel.syncError == .loginRequired())
        #expect(updates == [nil])
    }

    @Test("sync auth errors let PAT recovery decide whether Login is needed",
          .timeLimit(.minutes(1)),
          arguments: [PassCLIPATLoginResult.succeeded, .missingToken, .invalidToken, .failed("offline")])
    func authErrorsRouteThroughPATRecovery(result: PassCLIPATLoginResult) async throws {
        let harness = try makeHarness(error: CLIError.notLoggedIn)
        let viewModel = harness.viewModel
        let fallback = PassCLILoginNotifier(
            notificationRouter: nil,
            poster: SyncLoginNotificationPoster(),
            startLogin: {},
            showLoginRequired: {
                viewModel.syncProgress = nil
                viewModel.syncError = .loginRequired()
            }
        )
        var loginCount = 0
        let recovery = PassCLIPATAutoLoginCoordinator(
            credentialStore: SyncPATCredentialStore(token: result == .missingToken ? nil : "test-token"),
            loginWithSavedToken: {
                #expect(viewModel.syncError == nil, "Login must not appear before PAT login finishes")
                #expect(viewModel.syncProgress == .loggingInWithSavedPAT())
                loginCount += 1
                return result
            },
            fallbackHandler: fallback,
            patFailureHandler: { _ in },
            invalidPATHandler: { message in
                viewModel.syncProgress = nil
                viewModel.syncError = .invalidPAT(userFacingMessage: message)
            },
            autoLoginStartedHandler: {
                viewModel.syncError = nil
                viewModel.syncProgress = .loggingInWithSavedPAT()
            },
            browserLoginIsRunning: { false }
        )

        await confirmation("Sync immediately requests authentication recovery") { recoveryRequested in
            var updateCount = 0
            let coordinator = SyncCoordinator(
                cliService: harness.cliService,
                databaseManager: harness.databaseManager,
                viewModel: viewModel,
                onSyncIssueChanged: { _ in updateCount += 1 },
                onAuthenticationRequired: {
                    #expect(viewModel.syncError == nil, "Sync must not publish Login before deciding on PAT recovery")
                    recoveryRequested()
                    recovery.handleCLIHealthTransition(to: .notLoggedIn)
                }
            )
            coordinator.refreshNow()
            await waitForUpdateCount(1) { updateCount }
            await recovery.waitForCurrentAttempt()

            #expect(loginCount == (result == .missingToken ? 0 : 1))
            switch result {
            case .succeeded:
                #expect(viewModel.syncError == nil)
                #expect(viewModel.syncProgress == .loggingInWithSavedPAT())
            case .invalidToken:
                #expect(viewModel.syncError?.action == .updatePAT)
            default:
                #expect(viewModel.syncError?.action == .login)
            }
        }
    }

    @Test("auth errors do not overwrite an existing recovery presentation",
          .timeLimit(.minutes(1)), arguments: [false, true])
    func authErrorsPreserveRecoveryPresentation(invalidPAT: Bool) async throws {
        let harness = try makeHarness(error: CLIError.notLoggedIn)
        let expectedError: SyncErrorPresentation? = invalidPAT ? .invalidPAT(userFacingMessage: "Replace token") : nil
        harness.viewModel.syncError = expectedError
        harness.viewModel.syncProgress = invalidPAT ? nil : .loggingInWithSavedPAT()
        let expectedProgress = harness.viewModel.syncProgress

        await confirmation("Recovery handler owns presentation") { recoveryRequested in
            var updateCount = 0
            let coordinator = SyncCoordinator(
                cliService: harness.cliService,
                databaseManager: harness.databaseManager,
                viewModel: harness.viewModel,
                onSyncIssueChanged: { _ in updateCount += 1 },
                onAuthenticationRequired: {
                    #expect(harness.viewModel.syncError == expectedError)
                    #expect(harness.viewModel.syncProgress == expectedProgress)
                    recoveryRequested()
                }
            )
            coordinator.refreshNow()
            await waitForUpdateCount(1) { updateCount }
            #expect(harness.viewModel.syncError == expectedError)
            #expect(harness.viewModel.syncProgress == expectedProgress)
        }
    }

    @Test("auth errors preserve active invalid PAT state")
    func authErrorsPreserveActiveInvalidPATState() async throws {
        let harness = try makeHarness(error: CLIError.notLoggedIn)
        let invalidPAT = SyncErrorPresentation.invalidPAT(
            userFacingMessage: "Personal access token is invalid, expired, or deleted."
        )
        harness.viewModel.syncError = invalidPAT
        var updates: [QuickAccessSyncIssuePresentation?] = []
        let coordinator = SyncCoordinator(
            cliService: harness.cliService,
            databaseManager: harness.databaseManager,
            viewModel: harness.viewModel,
            onSyncIssueChanged: { presentation in
                updates.append(presentation)
            }
        )

        coordinator.refreshNow()
        await waitForUpdateCount(1) { updates.count }

        #expect(harness.viewModel.syncError == invalidPAT)
        #expect(updates == [nil])
    }

    @Test("generic sync errors clear stale progress")
    func genericSyncErrorsClearStaleProgress() async throws {
        let harness = try makeHarness(runner: VaultThenThrowingCLIRunner(error: CLIError.commandFailed("boom")))
        var updates: [QuickAccessSyncIssuePresentation?] = []
        let coordinator = SyncCoordinator(
            cliService: harness.cliService,
            databaseManager: harness.databaseManager,
            viewModel: harness.viewModel,
            onSyncIssueChanged: { presentation in
                updates.append(presentation)
            }
        )

        coordinator.refreshNow()
        await waitForUpdateCount(1) { updates.count }

        #expect(harness.viewModel.syncProgress == nil)
    }

    @Test("auth sync errors clear stale progress")
    func authSyncErrorsClearStaleProgress() async throws {
        let harness = try makeHarness(runner: VaultThenThrowingCLIRunner(error: CLIError.notLoggedIn))
        var updates: [QuickAccessSyncIssuePresentation?] = []
        let coordinator = SyncCoordinator(
            cliService: harness.cliService,
            databaseManager: harness.databaseManager,
            viewModel: harness.viewModel,
            onSyncIssueChanged: { presentation in
                updates.append(presentation)
            }
        )

        coordinator.refreshNow()
        await waitForUpdateCount(1) { updates.count }

        #expect(harness.viewModel.syncProgress == nil)
    }

    @Test("not installed errors resolve diagnostics window")
    func notInstalledErrorsResolveDiagnosticsWindow() async throws {
        let harness = try makeHarness(error: CLIError.notInstalled)
        var updates: [QuickAccessSyncIssuePresentation?] = []
        let coordinator = SyncCoordinator(
            cliService: harness.cliService,
            databaseManager: harness.databaseManager,
            viewModel: harness.viewModel,
            onSyncIssueChanged: { presentation in
                updates.append(presentation)
            }
        )

        coordinator.refreshNow()
        await waitForUpdateCount(1) { updates.count }

        #expect(harness.viewModel.syncError == nil)
        #expect(harness.viewModel.errorMessage == "pass-cli not found. Install: brew install protonpass/tap/pass-cli")
        #expect(updates == [nil])
    }

    private func makeHarness(error: CLIError) throws -> Harness {
        try makeHarness(runner: ThrowingCLIRunner(error: error))
    }

    private func makeHarness(runner: any CLIRunning) throws -> Harness {
        let databaseManager = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let cliService = PassCLIService(
            cliPath: "/usr/bin/pass",
            runner: runner
        )
        let viewModel = QuickAccessViewModel(
            searchService: SearchService(databaseManager: databaseManager),
            cliService: cliService,
            clipboardManager: ClipboardManager(autoClearSeconds: 0),
            onDismiss: {},
            writeStringToPasteboard: { _ in },
            openURL: { _ in true }
        )
        return Harness(
            databaseManager: databaseManager,
            cliService: cliService,
            viewModel: viewModel
        )
    }

    private func waitForUpdateCount(
        _ expectedCount: Int,
        currentCount: () -> Int
    ) async {
        for _ in 0..<100 {
            if currentCount() >= expectedCount { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor SyncPATCredentialStore: PassCLIPATCredentialStoring {
    private var token: String?
    init(token: String?) { self.token = token }
    func hasToken() async -> Bool { token != nil }
    func loadToken() async throws -> String? { token }
    func saveToken(_ token: String) async throws { self.token = token }
    func deleteToken() async throws { token = nil }
}

@MainActor
private final class SyncLoginNotificationPoster: PassCLILoginNotificationPosting {
    func postLoggedOutNotification() {}
    func postResultNotification(title: String, body: String, categoryIdentifier: String?) {}
}

private struct Harness {
    let databaseManager: DatabaseManager
    let cliService: PassCLIService
    let viewModel: QuickAccessViewModel
}

private struct ThrowingCLIRunner: CLIRunning {
    let error: CLIError

    func run(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> Data {
        throw error
    }
}

private actor VaultThenThrowingCLIRunner: CLIRunning {
    let error: CLIError

    init(error: CLIError) {
        self.error = error
    }

    func run(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> Data {
        if arguments.prefix(2) == ["vault", "list"] {
            return Data("""
            {"vaults":[{"vault_id":"vault","share_id":"share","name":"Personal"}]}
            """.utf8)
        }
        if arguments == ["--version"] {
            return Data("2.1.4".utf8)
        }
        throw error
    }
}
