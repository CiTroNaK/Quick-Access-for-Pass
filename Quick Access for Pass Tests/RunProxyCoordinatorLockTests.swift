import Testing
import Foundation
@testable import Quick_Access_for_Pass

@Suite("Run coordinator locked-path behavior")
@MainActor
struct RunProxyCoordinatorLockTests {

    @MainActor
    final class Recorder {
        var events: [String] = []
        var lastToken: UUID?
    }

    private func makeFixture(
        isLocked: Bool,
        panelResult: Bool
    ) throws -> (RunProxyCoordinator, Recorder, DatabaseManager) {
        let recorder = Recorder()
        let database = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))

        // Seed a minimal RunProfile so `findRunProfile(slug:)` succeeds on
        // the locked path before it bails.
        let profile = RunProfile(
            id: nil,
            name: "Test Profile",
            slug: "test-profile",
            cacheDuration: "",
            createdAt: Date()
        )
        _ = try database.saveRunProfile(profile, mappings: [])

        let coordinator = RunProxyCoordinator(
            cliService: PassCLIService(cliPath: nil),
            databaseManager: database,
            onError: { _ in },
            healthStore: ProxyHealthStore(),
            passCLIStatusStore: PassCLIStatusStore(),
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
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
        let controller = RunAuthWindowController(
            databaseManager: database,
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
            callbacks: .noop
        )

        let request = RunProxyRequest(
            profile: "test-profile",
            command: ["echo", "hello"],
            pid: Int32(ProcessInfo.processInfo.processIdentifier)
        )

        // The authController.authorize path drives a real NSWindow, so we
        // don't run it to completion. Detach the Task so it doesn't keep
        // the test waiting at scope end, yield so the non-locked branch
        // runs past the point where lock-context calls would happen, then
        // cancel.
        let task = Task {
            _ = await coordinator.authorizeRunRequest(
                request,
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

        let controller = RunAuthWindowController(
            databaseManager: database,
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
            callbacks: .noop
        )

        let request = RunProxyRequest(
            profile: "test-profile",
            command: ["echo", "hello"],
            pid: Int32(ProcessInfo.processInfo.processIdentifier)
        )

        let response = await coordinator.authorizeRunRequest(
            request,
            connection: stubConnection(),
            authController: controller
        )

        #expect(response.decision == .deny)
        #expect(response.env == nil)
        #expect(recorder.events == ["set", "showPanel", "clear(match)"])
    }
}
