import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("AppDelegate sync issue helpers")
@MainActor
struct AppDelegateSyncIssueTests {
    @Test("configured login notifier resolves visible diagnostics when logged out")
    func configuredLoginNotifierResolvesVisibleDiagnosticsWhenLoggedOut() throws {
        let harness = try makeHarness()
        let previous = QuickAccessSyncIssuePresentation.syncError(
            .genericFailure(diagnosticReport: "old diagnostic")
        )
        harness.controller.show(presentation: previous, relativeTo: nil)
        harness.appDelegate.setupPassCLIAuthenticationCoordinators(
            cliService: harness.cliService,
            notificationPoster: FakeLoginNotificationPoster(),
            requestsAuthorization: false
        )
        let notifier = try #require(harness.appDelegate.passCLILoginNotifier)
        harness.viewModel.syncProgress = .vaultStarted(vaultName: "Personal")

        notifier.handleCLIHealthTransition(to: .notLoggedIn)

        #expect(harness.viewModel.syncProgress == nil)
        #expect(harness.viewModel.syncError == .loginRequired())
        #expect(harness.controller.debugState == .resolved(previous))
    }

    @Test("PAT auto-login helper replaces stale Login with progress")
    func patAutoLoginHelperReplacesStaleLoginWithProgress() throws {
        let harness = try makeHarness()
        harness.viewModel.syncError = .loginRequired()
        harness.viewModel.errorMessage = "old error"

        harness.appDelegate.showPATAutoLoginSyncProgress()

        #expect(harness.viewModel.errorMessage == nil)
        #expect(harness.viewModel.syncError == nil)
        #expect(harness.viewModel.syncProgress == .loggingInWithSavedPAT())
    }

    @Test("invalid PAT helper clears stale progress and resolves visible diagnostics")
    func invalidPATHelperClearsStaleProgressAndResolvesVisibleDiagnostics() throws {
        let harness = try makeHarness()
        let previous = QuickAccessSyncIssuePresentation.syncError(
            .genericFailure(diagnosticReport: "old diagnostic")
        )
        harness.controller.show(presentation: previous, relativeTo: nil)
        harness.viewModel.syncProgress = .vaultStarted(vaultName: "Personal")

        harness.appDelegate.showInvalidPATSyncIssue(
            userFacingMessage: "Personal access token is invalid, expired, or deleted. Replace it in Settings → Pass CLI or log in normally."
        )

        #expect(harness.viewModel.syncProgress == nil)
        #expect(harness.viewModel.syncError == .invalidPAT(
            userFacingMessage: "Personal access token is invalid, expired, or deleted. Replace it in Settings → Pass CLI or log in normally."
        ))
        #expect(harness.controller.debugState == .resolved(previous))
    }

    @Test("configured login notifier resolves visible diagnostics when login clears")
    func configuredLoginNotifierResolvesVisibleDiagnosticsWhenLoginClears() throws {
        let harness = try makeHarness()
        let previous = QuickAccessSyncIssuePresentation.syncError(
            .genericFailure(diagnosticReport: "old diagnostic")
        )
        harness.viewModel.syncError = .loginRequired()
        harness.controller.show(presentation: previous, relativeTo: nil)
        harness.appDelegate.setupPassCLIAuthenticationCoordinators(
            cliService: harness.cliService,
            notificationPoster: FakeLoginNotificationPoster(),
            requestsAuthorization: false
        )
        let notifier = try #require(harness.appDelegate.passCLILoginNotifier)

        notifier.handleCLIHealthTransition(to: .ok)

        #expect(harness.viewModel.syncError == nil)
        #expect(harness.controller.debugState == .resolved(previous))
    }

    @Test("opening Pass CLI settings selects Pass CLI tab")
    func openingPassCLISettingsSelectsPassCLITab() throws {
        let previous = UserDefaults.standard.string(forKey: DefaultsKey.selectedSettingsTab)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: DefaultsKey.selectedSettingsTab)
            } else {
                UserDefaults.standard.removeObject(forKey: DefaultsKey.selectedSettingsTab)
            }
        }
        UserDefaults.standard.removeObject(forKey: DefaultsKey.selectedSettingsTab)
        let harness = try makeHarness()

        harness.appDelegate.openPassCLISettings()

        #expect(UserDefaults.standard.string(forKey: DefaultsKey.selectedSettingsTab) == SettingsTab.passCLI.rawValue)
    }

    @Test("configured login notifier preserves invalid PAT state when logged out")
    func configuredLoginNotifierPreservesInvalidPATStateWhenLoggedOut() throws {
        let harness = try makeHarness()
        let invalidPAT = SyncErrorPresentation.invalidPAT(
            userFacingMessage: "Personal access token is invalid, expired, or deleted."
        )
        harness.viewModel.syncError = invalidPAT
        harness.appDelegate.setupPassCLIAuthenticationCoordinators(
            cliService: harness.cliService,
            notificationPoster: FakeLoginNotificationPoster(),
            requestsAuthorization: false
        )
        let notifier = try #require(harness.appDelegate.passCLILoginNotifier)

        notifier.handleCLIHealthTransition(to: .notLoggedIn)

        #expect(harness.viewModel.syncError == invalidPAT)
    }

    @Test("configured login notifier clears invalid PAT state when login clears")
    func configuredLoginNotifierClearsInvalidPATStateWhenLoginClears() throws {
        let harness = try makeHarness()
        let previous = QuickAccessSyncIssuePresentation.syncError(
            .genericFailure(diagnosticReport: "old diagnostic")
        )
        harness.viewModel.syncError = .invalidPAT(userFacingMessage: "Personal access token is invalid, expired, or deleted.")
        harness.controller.show(presentation: previous, relativeTo: nil)
        harness.appDelegate.setupPassCLIAuthenticationCoordinators(
            cliService: harness.cliService,
            notificationPoster: FakeLoginNotificationPoster(),
            requestsAuthorization: false
        )
        let notifier = try #require(harness.appDelegate.passCLILoginNotifier)

        notifier.handleCLIHealthTransition(to: .ok)

        #expect(harness.viewModel.syncError == nil)
        #expect(harness.controller.debugState == .resolved(previous))
    }

    private func makeHarness() throws -> Harness {
        let appDelegate = AppDelegate()
        let databaseManager = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let cliService = PassCLIService()
        let viewModel = QuickAccessViewModel(
            searchService: SearchService(databaseManager: databaseManager),
            cliService: cliService,
            clipboardManager: ClipboardManager(autoClearSeconds: 0),
            onDismiss: {},
            writeStringToPasteboard: { _ in },
            openURL: { _ in true }
        )
        let controller = SyncIssueWindowController(
            actions: .init(
                copyReport: { _ in },
                copyAndReport: { _ in },
                copySkippedItemCommand: { _ in },
                dismissIssue: { _ in }
            ),
            presentationMode: .headless
        )
        appDelegate.viewModel = viewModel
        appDelegate.syncIssueWindowController = controller
        return Harness(
            appDelegate: appDelegate,
            cliService: cliService,
            viewModel: viewModel,
            controller: controller
        )
    }
}

private struct Harness {
    let appDelegate: AppDelegate
    let cliService: PassCLIService
    let viewModel: QuickAccessViewModel
    let controller: SyncIssueWindowController
}

@MainActor
private final class FakeLoginNotificationPoster: PassCLILoginNotificationPosting {
    func postLoggedOutNotification() {}

    func postResultNotification(title: String, body: String, categoryIdentifier: String?) {}
}
