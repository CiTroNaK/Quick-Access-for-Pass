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
