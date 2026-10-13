import Testing
import Foundation
@testable import Quick_Access_for_Pass

private actor SecretResolutionRecorder {
    private var count = 0

    func record() {
        count += 1
    }

    func countValue() -> Int {
        count
    }
}

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
        panelResult: Bool,
        secretResolver: @escaping @Sendable ([RunProfileEnvMapping], String) async throws -> [String: String] = { _, _ in [:] }
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
            authCallbacks: .noop,
            secretResolver: secretResolver
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
            callbacks: .noop,
            dialogPresenter: { $0.onResult(false, .doNotRemember, $0.scopeOptions.first?.key) }
        )

        let request = RunProxyRequest(
            profile: "test-profile",
            command: ["echo", "hello"],
            pid: Int32(ProcessInfo.processInfo.processIdentifier)
        )

        let response = await coordinator.authorizeRunRequest(
            request, connection: stubConnection(), authController: controller
        )
        #expect(response.decision == .deny)
        #expect(response.env == nil)

        #expect(recorder.events.contains("set") == false)
        #expect(recorder.events.contains("showPanel") == false)

    }

    @Test(arguments: [false, true], [false, true])
    func cachedDenialSkipsLockUiAndSecretResolution(broaderSessionApproval: Bool, exactDenial: Bool) async throws {
        let resolutionRecorder = SecretResolutionRecorder()
        let (coordinator, recorder, database) = try makeFixture(
            isLocked: true,
            panelResult: true,
            secretResolver: { _, _ in
                await resolutionRecorder.record()
                return ["TOKEN": "test"]
            }
        )
        let controller = RunAuthWindowController(
            databaseManager: database,
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
            callbacks: .noop
        )
        let profile = try #require(try database.findRunProfile(slug: "test-profile"))
        _ = try database.saveRunProfile(
            profile,
            mappings: [
                RunProfileEnvMapping(
                    id: nil,
                    profileId: profile.id ?? 0,
                    envVariable: "TOKEN",
                    secretReference: "pass://vault/item/field"
                ),
            ]
        )
        let connection = stubConnection()
        let identity = try #require(controller.resolveIdentity(for: connection, profile: "test-profile"))
        try database.saveRunDecision(
            appIdentifier: identity.appIdentifier,
            subcommand: exactDenial ? try #require(RunAuthorizationScope.exact(command: ["gh", "pr", "list"])).key : "gh pr list",
            profileSlug: "test-profile",
            expiresAt: Date().addingTimeInterval(300),
            allowed: false
        )
        if broaderSessionApproval {
            controller.storeSessionCache(
                appIdentifier: identity.appIdentifier,
                profileSlug: "test-profile",
                scope: "gh pr",
                allowed: true
            )
        }
        let request = RunProxyRequest(
            profile: "test-profile",
            command: ["gh", "pr", "list"],
            pid: Int32(ProcessInfo.processInfo.processIdentifier)
        )

        let response = await coordinator.authorizeRunRequest(
            request,
            connection: connection,
            authController: controller
        )

        #expect(response.decision == .deny)
        #expect(response.env == nil)
        #expect(recorder.events.isEmpty)
        #expect(await resolutionRecorder.countValue() == 0)
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
