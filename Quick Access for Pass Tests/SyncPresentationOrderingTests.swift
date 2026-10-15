import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Sync presentation ownership", .timeLimit(.minutes(1)))
@MainActor
struct SyncPresentationOrderingTests {
    @Test("late cancelled work cannot clear or replace newer presentation", arguments: ["progress", "failure", "notInstalled", "auth"])
    func ignoresStalePresentation(outcome: String) async throws {
        let oldNative = OwnershipPause()
        let newerIdentity = OwnershipPause()
        let runner = PresentationOrderingRunner(oldNative: oldNative, outcome: outcome)
        let database = try DatabaseManager(inMemory: true, passphrase: Data("synthetic".utf8))
        let cli = PassCLIService(cliPath: "/synthetic/pass-cli", runner: runner)
        let viewModel = makeViewModel(database: database, cli: cli)
        let suite = "SyncPresentationOrderingTests.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(1234.0, forKey: DefaultsKey.lastSyncTime)
        let coordinator = SyncCoordinator(
            cliService: cli, databaseManager: database, viewModel: viewModel,
            identitySynchronizer: PresentationIdentityBarrier(pause: newerIdentity), defaults: preferences
        )
        coordinator.refreshNow()
        let oldCompletion = try #require(coordinator.currentSyncCompletion)
        await oldNative.waitUntilEntered()
        coordinator.refreshNow()
        let newCompletion = try #require(coordinator.currentSyncCompletion)
        await newerIdentity.waitUntilEntered()
        let currentProgress = viewModel.syncProgress
        await oldNative.finish()
        await oldCompletion.value
        #expect(viewModel.isLoading)
        #expect(viewModel.syncProgress == currentProgress)
        #expect(viewModel.syncError == nil)
        #expect(viewModel.errorMessage == nil)
        #expect(preferences.double(forKey: DefaultsKey.lastSyncTime) == 1234)
        await newerIdentity.finish()
        await newCompletion.value
        #expect(!viewModel.isLoading)
        #expect(preferences.double(forKey: DefaultsKey.lastSyncTime) != 1234)
    }

    @Test("reset reconciles post-clear identities even if replacement sync cannot authenticate")
    func resetPublishesEmptyIdentitiesBeforeFailedRefresh() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("synthetic".utf8))
        let cli = PassCLIService(cliPath: "/synthetic/pass-cli", runner: ResetAuthenticationFailureRunner())
        let viewModel = makeViewModel(database: database, cli: cli)
        let synchronizer = ResetIdentityRecorder()
        let finished = SyncOrderingSignal()
        let coordinator = SyncCoordinator(
            cliService: cli, databaseManager: database, viewModel: viewModel,
            identitySynchronizer: synchronizer, onSyncIssueChanged: { _ in finished.signal() }
        )
        coordinator.resetAndSync()
        await finished.wait()
        await coordinator.currentSyncCompletion?.value
        #expect(await synchronizer.batches() == [[]])
    }

    private func makeViewModel(database: DatabaseManager, cli: PassCLIService) -> QuickAccessViewModel {
        QuickAccessViewModel(
            searchService: SearchService(databaseManager: database), cliService: cli,
            clipboardManager: ClipboardManager(autoClearSeconds: 0), onDismiss: {},
            writeStringToPasteboard: { _ in }, openURL: { _ in true }
        )
    }
}

private actor PresentationOrderingRunner: CLIRunning {
    private let oldNative: OwnershipPause
    private let outcome: String
    private var vaultCalls = 0

    init(oldNative: OwnershipPause, outcome: String) {
        self.oldNative = oldNative
        self.outcome = outcome
    }

    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        if arguments == ["--version"] { return Data("2.4.2".utf8) }
        if arguments == ["vault", "list", "--output", "json"] {
            vaultCalls += 1
            let call = vaultCalls
            if call == 1 {
                await oldNative.suspend()
                switch outcome {
                case "failure": throw CLIError.commandFailed("Synthetic late failure")
                case "notInstalled": throw CLIError.notInstalled
                case "auth": throw CLIError.notLoggedIn
                default: break
                }
            }
            let name = call == 1 ? "Older" : "Newer"
            return Data("{\"vaults\":[{\"name\":\"\(name)\",\"vault_id\":\"vault\",\"share_id\":\"share\"}]}".utf8)
        }
        return Data(#"{"items":[]}"#.utf8)
    }
}

private actor PresentationIdentityBarrier: AutoFillIdentitySynchronizing {
    let pause: OwnershipPause
    init(pause: OwnershipPause) { self.pause = pause }
    func reconcile(descriptors: [AutoFillCredentialDescriptor], isCurrent: @escaping @Sendable () -> Bool) async throws {
        await pause.suspend()
        guard isCurrent() else { throw CancellationError() }
    }
}

private struct ResetAuthenticationFailureRunner: CLIRunning {
    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        throw CLIError.notLoggedIn
    }
}

private actor ResetIdentityRecorder: AutoFillIdentitySynchronizing {
    private var recorded: [[AutoFillCredentialDescriptor]] = []
    func reconcile(descriptors: [AutoFillCredentialDescriptor], isCurrent: @escaping @Sendable () -> Bool) async throws {
        guard isCurrent() else { throw CancellationError() }
        recorded.append(descriptors)
    }
    func batches() -> [[AutoFillCredentialDescriptor]] { recorded }
}
