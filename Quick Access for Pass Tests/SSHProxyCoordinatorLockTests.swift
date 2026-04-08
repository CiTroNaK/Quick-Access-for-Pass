import Testing
import Foundation
@testable import Quick_Access_for_Pass

@Suite("SSH coordinator locked-path behavior")
@MainActor
struct SSHProxyCoordinatorLockTests {

    /// Recorder capturing the closure-call sequence so tests can
    /// assert the exact set→clear ordering with the matching token.
    @MainActor
    final class Recorder {
        var events: [String] = []
        var lastToken: UUID?
    }

    private func makeFixture(
        isLocked: Bool,
        panelResult: Bool
    ) throws -> (SSHProxyCoordinator, Recorder, DatabaseManager) {
        let recorder = Recorder()
        let database = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let coordinator = SSHProxyCoordinator(
            cliService: PassCLIService(cliPath: nil),
            databaseManager: database,
            onError: { _ in },
            healthStore: ProxyHealthStore(),
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
            passCLIStatusStore: PassCLIStatusStore(),
            authCallbacks: .noop
        )
        coordinator.isAppLocked = { isLocked }
        coordinator.showLockedPanel = {
            recorder.events.append("showPanel")
            return panelResult
        }
        coordinator.setPendingLockContext = { _ in
            let token = UUID()
            recorder.events.append("set")
            recorder.lastToken = token
            return token
        }
        coordinator.clearPendingLockContext = { token in
            if token == recorder.lastToken {
                recorder.events.append("clear(match)")
            } else {
                recorder.events.append("clear(stale)")
            }
        }
        return (coordinator, recorder, database)
    }

    private func stubConnection() -> VerifiedConnection {
        VerifiedConnection(
            fd: -1,
            identity: .trustedHelper,
            pid: ProcessInfo.processInfo.processIdentifier
        )
    }

    @Test func unlockedPathSkipsLockUiAndDoesNotSetContext() async throws {
        let (coordinator, recorder, database) = try makeFixture(isLocked: false, panelResult: false)
        let controller = SSHAuthWindowController(
            databaseManager: database,
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
            callbacks: .noop
        )

        // The authController.authorize path drives a real NSWindow, so we
        // don't run it to completion. Detach the Task so it doesn't keep
        // the test waiting at scope end, yield so the non-locked branch
        // runs past the point where lock-context calls would happen, then
        // cancel.
        let task = Task {
            _ = await coordinator.authorizeProxyRequest(
                keyBlob: Data("key".utf8),
                connection: stubConnection(),
                authController: controller
            )
        }
        for _ in 0..<10 { await Task.yield() }

        #expect(recorder.events.contains("set") == false)
        #expect(recorder.events.contains("showPanel") == false)

        task.cancel()
        controller.cancelAll()
    }

    @Test func lockedAndPanelDeniesReturnsDenyAndClearsContext() async throws {
        let (coordinator, recorder, database) = try makeFixture(isLocked: true, panelResult: false)

        let controller = SSHAuthWindowController(
            databaseManager: database,
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
            callbacks: .noop
        )

        let result = await coordinator.authorizeProxyRequest(
            keyBlob: Data("key".utf8),
            connection: stubConnection(),
            authController: controller
        )

        #expect(result == .deny)
        #expect(recorder.events == ["set", "showPanel", "clear(match)"])
    }
}
