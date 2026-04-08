import Testing
import Foundation
@testable import Quick_Access_for_Pass

@MainActor
@Suite("RunProxyCoordinator — thin")
struct RunProxyCoordinatorTests {

    private let suiteName: String
    private let defaults: UserDefaults

    init() throws {
        let name = "test-run-\(UUID().uuidString)"
        self.suiteName = name
        self.defaults = try #require(UserDefaults(suiteName: name))
    }

    private func cleanup() {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func makeCoordinator() throws -> (RunProxyCoordinator, ErrorBox) {
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let errors = ErrorBox()
        let coordinator = RunProxyCoordinator(
            cliService: PassCLIService(cliPath: "/bin/false"),
            databaseManager: db,
            onError: { [errors] message in errors.messages.append(message) },
            healthStore: ProxyHealthStore(),
            passCLIStatusStore: PassCLIStatusStore(),
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
            defaults: defaults
        )
        return (coordinator, errors)
    }

    @Test("coordinator constructs without error")
    func initDoesNotCrash() throws {
        defer { cleanup() }
        let (_, errors) = try makeCoordinator()
        #expect(errors.messages.isEmpty)
    }

    @Test("reconcile with runProxyEnabled=false is a no-op on fresh state")
    func reconcileDisabledIsNoop() async throws {
        defer { cleanup() }
        defaults.set(false, forKey: DefaultsKey.runProxyEnabled)
        let (coordinator, errors) = try makeCoordinator()
        await coordinator.reconcile()
        #expect(errors.messages.isEmpty)
    }

    @Test("teardown on fresh coordinator is idempotent")
    func teardownOnFreshCoordinatorDoesNotCrash() async throws {
        defer { cleanup() }
        let (coordinator, errors) = try makeCoordinator()
        await coordinator.teardown()
        await coordinator.teardown()
        #expect(errors.messages.isEmpty)
    }

    @Test("handleWake restarts proxy when proxy is nil but toggle is enabled")
    func handleWakeRestartsWhenNilProxy() async throws {
        defer { cleanup() }
        defaults.set(true, forKey: DefaultsKey.runProxyEnabled)
        let (coordinator, _) = try makeCoordinator()

        // Simulate: toggle was enabled, proxy started, then proxy died.
        coordinator.lastEnabled = true

        // Seed autoHeal with stale failure state to verify reset.
        _ = coordinator.autoHeal.recordFailure(now: Date())

        await coordinator.handleWake()

        // startProxy() will fail (cliPath is /bin/false) but auto-heal
        // should be reset.
        #expect(coordinator.autoHeal.consecutiveFailures == 0)
        #expect(coordinator.autoHeal.lastRestartAt == nil)
    }

    @Test("handleWake does nothing when proxy is nil and toggle is disabled")
    func handleWakeNoopWhenDisabled() async throws {
        defer { cleanup() }
        let (coordinator, errors) = try makeCoordinator()

        // lastEnabled is false (default), proxy is nil — should return silently.
        await coordinator.handleWake()
        #expect(errors.messages.isEmpty)
    }

    // MARK: - CLI health propagation

    private struct FakeRunner: CLIRunning {
        let behavior: @Sendable (_ args: [String]) async throws -> Data
        func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
            try await behavior(arguments)
        }
    }

    @Test("CLI notLoggedIn sets runHealth to unreachable(.passCLINotLoggedIn)")
    func cliNotLoggedInSetsUnreachable() async throws {
        defer { cleanup() }
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let healthStore = ProxyHealthStore()
        let coordinator = RunProxyCoordinator(
            cliService: PassCLIService(cliPath: "/fake/pass-cli"),
            databaseManager: db,
            onError: { _ in },
            healthStore: healthStore,
            passCLIStatusStore: PassCLIStatusStore(),
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
            defaults: defaults
        )
        healthStore.runHealth = .ok()

        coordinator.handleCLIHealthTransition(to: .notLoggedIn)

        #expect(healthStore.runHealth == .unreachable(.passCLINotLoggedIn))
    }

    @Test("CLI notInstalled sets runHealth to unreachable(.passCLIFailed)")
    func cliNotInstalledSetsUnreachable() async throws {
        defer { cleanup() }
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let healthStore = ProxyHealthStore()
        let coordinator = RunProxyCoordinator(
            cliService: PassCLIService(cliPath: "/fake/pass-cli"),
            databaseManager: db,
            onError: { _ in },
            healthStore: healthStore,
            passCLIStatusStore: PassCLIStatusStore(),
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
            defaults: defaults
        )
        healthStore.runHealth = .ok()

        coordinator.handleCLIHealthTransition(to: .notInstalled)

        #expect(healthStore.runHealth == .unreachable(.passCLIFailed("pass-cli not found")))
    }

    @Test("CLI failed sets runHealth to unreachable(.passCLIFailed)")
    func cliFailedSetsUnreachable() async throws {
        defer { cleanup() }
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let healthStore = ProxyHealthStore()
        let coordinator = RunProxyCoordinator(
            cliService: PassCLIService(cliPath: "/fake/pass-cli"),
            databaseManager: db,
            onError: { _ in },
            healthStore: healthStore,
            passCLIStatusStore: PassCLIStatusStore(),
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
            defaults: defaults
        )
        healthStore.runHealth = .ok()

        coordinator.handleCLIHealthTransition(to: .failed(reason: "disk full"))

        #expect(healthStore.runHealth == .unreachable(.passCLIFailed("disk full")))
    }

    @Test("CLI ok clears CLI-caused unreachable state")
    func cliOkClearsCLICausedState() async throws {
        defer { cleanup() }
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let healthStore = ProxyHealthStore()
        let coordinator = RunProxyCoordinator(
            cliService: PassCLIService(cliPath: "/fake/pass-cli"),
            databaseManager: db,
            onError: { _ in },
            healthStore: healthStore,
            passCLIStatusStore: PassCLIStatusStore(),
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
            defaults: defaults
        )
        healthStore.runHealth = .unreachable(.passCLINotLoggedIn)

        coordinator.handleCLIHealthTransition(to: .ok)

        #expect(healthStore.runHealth == .ok())
    }

    @Test("CLI ok does not override probe-based failure")
    func cliOkPreservesProbeFailure() async throws {
        defer { cleanup() }
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let healthStore = ProxyHealthStore()
        let coordinator = RunProxyCoordinator(
            cliService: PassCLIService(cliPath: "/fake/pass-cli"),
            databaseManager: db,
            onError: { _ in },
            healthStore: healthStore,
            passCLIStatusStore: PassCLIStatusStore(),
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
            defaults: defaults
        )
        healthStore.runHealth = .unreachable(.cooldown)

        coordinator.handleCLIHealthTransition(to: .ok)

        #expect(healthStore.runHealth == .unreachable(.cooldown),
                "CLI ok should not override probe-based failure")
    }
}

@Suite("RunProxyCoordinator.nextRunHealth")
struct RunProxyCoordinatorNextHealthTests {
    @Test("healthy probe preserves unreachable(.passCLINotLoggedIn)")
    func preservesPassCLINotLoggedIn() {
        let current = ProxyHealthState.unreachable(.passCLINotLoggedIn)
        #expect(RunProxyCoordinator.nextRunHealth(onHealthyProbeGiven: current) == current)
    }

    @Test("healthy probe preserves unreachable(.passCLIFailed)")
    func preservesPassCLIFailed() {
        let current = ProxyHealthState.unreachable(.passCLIFailed("Command is not logout there is no session"))
        #expect(RunProxyCoordinator.nextRunHealth(onHealthyProbeGiven: current) == current)
    }

    @Test(arguments: [
        ProxyHealthState.ok(),
        ProxyHealthState.disabled,
        ProxyHealthState.degraded(.probeFailed),
        ProxyHealthState.degraded(.clientLoopFailure),
        ProxyHealthState.degraded(.emptyIdentities),
        ProxyHealthState.unreachable(.cooldown),
        ProxyHealthState.unreachable(.probeFailed),
        ProxyHealthState.unreachable(.clientLoopFailure),
        ProxyHealthState.unreachable(.emptyIdentities),
    ])
    func clearsRecoverableState(current: ProxyHealthState) {
        #expect(RunProxyCoordinator.nextRunHealth(onHealthyProbeGiven: current) == .ok(),
                "probe success should flip \(current) to .ok()")
    }
}
