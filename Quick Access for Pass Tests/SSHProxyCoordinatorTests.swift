import Testing
import Foundation
@testable import Quick_Access_for_Pass

@MainActor
@Suite("SSHProxyCoordinator — thin")
struct SSHProxyCoordinatorTests {

    private let suiteName: String
    private let defaults: UserDefaults

    init() throws {
        let name = "test-ssh-\(UUID().uuidString)"
        self.suiteName = name
        self.defaults = try #require(UserDefaults(suiteName: name))
    }

    private func cleanup() {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func makeCoordinator() throws -> (SSHProxyCoordinator, ErrorBox) {
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let errors = ErrorBox()
        let coordinator = SSHProxyCoordinator(
            cliService: PassCLIService(cliPath: "/bin/false"),
            databaseManager: db,
            onError: { [errors] message in errors.messages.append(message) },
            healthStore: ProxyHealthStore(),
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
            passCLIStatusStore: PassCLIStatusStore(),
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

    @Test("reconcile with sshProxyEnabled=false is a no-op on fresh state")
    func reconcileDisabledIsNoop() async throws {
        defer { cleanup() }
        defaults.set(false, forKey: DefaultsKey.sshProxyEnabled)
        let (coordinator, errors) = try makeCoordinator()
        await coordinator.reconcile()
        #expect(errors.messages.isEmpty)
    }

    @Test("reconcile is a no-op when nothing changed since last apply")
    func reconcileNoChangeIsNoop() async throws {
        defer { cleanup() }
        defaults.set(false, forKey: DefaultsKey.sshProxyEnabled)
        let (coordinator, errors) = try makeCoordinator()

        await coordinator.reconcile()  // first apply captures snapshot
        await coordinator.reconcile()  // second should be a no-op

        #expect(errors.messages.isEmpty)
    }

    @Test("reconcile restarts proxy when only the cliPath changes")
    func reconcileRestartsOnCLIPathChange() async throws {
        defer { cleanup() }
        defaults.set(true, forKey: DefaultsKey.sshProxyEnabled)

        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let cli = PassCLIService(cliPath: "/initial/pass-cli")
        let coordinator = SSHProxyCoordinator(
            cliService: cli,
            databaseManager: db,
            onError: { _ in },
            healthStore: ProxyHealthStore(),
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
            passCLIStatusStore: PassCLIStatusStore(),
            defaults: defaults
        )

        // Seed coordinator as if proxy is already running with an initial path.
        coordinator.lastEnabled = true
        coordinator.lastCliPath = "/initial/pass-cli"

        // Change the cliPath on the shared service. Everything else stays the same.
        cli.updateCLIPath("/new/pass-cli")

        await coordinator.reconcile()

        // Reconcile must pick up the new path and mark it applied.
        #expect(coordinator.lastCliPath == "/new/pass-cli")
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
        defaults.set(true, forKey: DefaultsKey.sshProxyEnabled)
        let (coordinator, _) = try makeCoordinator()

        // Simulate: toggle was enabled, proxy started, then proxy died.
        coordinator.lastEnabled = true

        // Seed autoHeal with stale failure state to verify reset.
        _ = coordinator.autoHeal.recordFailure(now: Date())

        await coordinator.handleWake()

        // startProxy() will fail (cliPath is /bin/false) but the attempt
        // should be made — auto-heal should be reset (consecutiveFailures == 0).
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

    @Test("CLI notLoggedIn with SSH enabled sets sshHealth to unreachable")
    func cliNotLoggedInSetsUnreachable() async throws {
        defer { cleanup() }
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let healthStore = ProxyHealthStore()
        let cliStore = PassCLIStatusStore()
        let coordinator = SSHProxyCoordinator(
            cliService: PassCLIService(cliPath: "/bin/false"),
            databaseManager: db,
            onError: { _ in },
            healthStore: healthStore,
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
            passCLIStatusStore: cliStore,
            defaults: defaults
        )
        coordinator.lastEnabled = true
        healthStore.sshHealth = .ok()

        await coordinator.handleCLIHealthTransition(to: .notLoggedIn)

        #expect(healthStore.sshHealth == .unreachable(.passCLINotLoggedIn))
    }

    @Test("CLI notInstalled with SSH enabled sets sshHealth to unreachable")
    func cliNotInstalledSetsUnreachable() async throws {
        defer { cleanup() }
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let healthStore = ProxyHealthStore()
        let cliStore = PassCLIStatusStore()
        let coordinator = SSHProxyCoordinator(
            cliService: PassCLIService(cliPath: "/bin/false"),
            databaseManager: db,
            onError: { _ in },
            healthStore: healthStore,
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
            passCLIStatusStore: cliStore,
            defaults: defaults
        )
        coordinator.lastEnabled = true
        healthStore.sshHealth = .ok()

        await coordinator.handleCLIHealthTransition(to: .notInstalled)

        #expect(healthStore.sshHealth == .unreachable(.passCLIFailed("pass-cli not found")))
    }

    @Test("CLI failed with SSH enabled sets sshHealth to unreachable")
    func cliFailedSetsUnreachable() async throws {
        defer { cleanup() }
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let healthStore = ProxyHealthStore()
        let cliStore = PassCLIStatusStore()
        let coordinator = SSHProxyCoordinator(
            cliService: PassCLIService(cliPath: "/bin/false"),
            databaseManager: db,
            onError: { _ in },
            healthStore: healthStore,
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
            passCLIStatusStore: cliStore,
            defaults: defaults
        )
        coordinator.lastEnabled = true
        healthStore.sshHealth = .ok()

        await coordinator.handleCLIHealthTransition(to: .failed(reason: "timeout"))

        #expect(healthStore.sshHealth == .unreachable(.passCLIFailed("timeout")))
    }

    @Test("CLI ok with proxy nil and SSH enabled attempts a real restart")
    func cliOkWithNilProxyAttemptsRestart() async throws {
        defer { cleanup() }
        defaults.set(true, forKey: DefaultsKey.sshProxyEnabled)
        let (coordinator, _) = try makeCoordinator()

        coordinator.lastEnabled = true
        coordinator.healthStore.sshHealth = .unreachable(.passCLIFailed("old reason"))
        _ = coordinator.autoHeal.recordFailure(now: Date())

        await coordinator.handleCLIHealthTransition(to: .ok)

        // Same observation pattern as handleWakeRestartsWhenNilProxy: the restart
        // path resets autoHeal, and startProxy() then bails out because
        // authWindowController is nil in this thin test (setup() was not called).
        // autoHeal.consecutiveFailures == 0 is the observable signal that the
        // restart path ran, not the cosmetic-flip path.
        #expect(coordinator.autoHeal.consecutiveFailures == 0)
        #expect(coordinator.autoHeal.lastRestartAt == nil)
        // sshHealth is NOT cosmetically flipped to .ok() in the nil-proxy case.
        // It keeps whatever value startProxy's bail-out left behind.
        #expect(coordinator.healthStore.sshHealth != .ok())
    }

    @Test("CLI ok with proxy nil but SSH disabled is a no-op")
    func cliOkWithNilProxyAndDisabledIsNoop() async throws {
        defer { cleanup() }
        let (coordinator, errors) = try makeCoordinator()
        // lastEnabled defaults to false
        coordinator.healthStore.sshHealth = .disabled

        await coordinator.handleCLIHealthTransition(to: .ok)

        #expect(coordinator.healthStore.sshHealth == .disabled)
        #expect(errors.messages.isEmpty)
    }

    @Test("CLI ok does not override probe-based failure")
    func cliOkPreservesProbeFailure() async throws {
        defer { cleanup() }
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let healthStore = ProxyHealthStore()
        let cliStore = PassCLIStatusStore()
        let coordinator = SSHProxyCoordinator(
            cliService: PassCLIService(cliPath: "/bin/false"),
            databaseManager: db,
            onError: { _ in },
            healthStore: healthStore,
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
            passCLIStatusStore: cliStore,
            defaults: defaults
        )
        coordinator.lastEnabled = true
        healthStore.sshHealth = .unreachable(.cooldown)

        await coordinator.handleCLIHealthTransition(to: .ok)

        #expect(healthStore.sshHealth == .unreachable(.cooldown))
    }

    @Test("CLI unhealthy with SSH disabled does not change sshHealth")
    func cliUnhealthyWithSSHDisabledIsNoop() async throws {
        defer { cleanup() }
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let healthStore = ProxyHealthStore()
        let cliStore = PassCLIStatusStore()
        let coordinator = SSHProxyCoordinator(
            cliService: PassCLIService(cliPath: "/bin/false"),
            databaseManager: db,
            onError: { _ in },
            healthStore: healthStore,
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
            passCLIStatusStore: cliStore,
            defaults: defaults
        )
        // lastEnabled defaults to false
        healthStore.sshHealth = .disabled

        await coordinator.handleCLIHealthTransition(to: .notLoggedIn)

        #expect(healthStore.sshHealth == .disabled)
    }

    // MARK: - EH3 race (moved from HealthCheckCoordinatorTests)

    @Test("applySSHProbeResult preserves passCLIFailed state on healthy result")
    func applySSHProbeResultPreservesPassCLIFailedStateOnHealthy() async throws {
        defer { cleanup() }
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let healthStore = ProxyHealthStore()
        let coordinator = SSHProxyCoordinator(
            cliService: PassCLIService(cliPath: "/fake/pass-cli"),
            databaseManager: db,
            onError: { _ in },
            healthStore: healthStore,
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
            passCLIStatusStore: PassCLIStatusStore(),
            defaults: defaults
        )
        coordinator.lastEnabled = true
        healthStore.sshHealth = .unreachable(.passCLIFailed("test-stale"))

        // Pins the wiring between applySSHProbeResult and nextSSHHealth:
        // if applySSHProbeResult ever stopped calling nextSSHHealth and
        // wrote .ok(detail:) directly, this test would fail.
        await coordinator.applySSHProbeResult(.healthy(identityCount: 2))

        #expect(healthStore.sshHealth == .unreachable(.passCLIFailed("test-stale")))
    }

    @Test("applySSHProbeResult writes .ok on healthy when state is recoverable")
    func applySSHProbeResultWritesOkOnHealthyRecoverableState() async throws {
        defer { cleanup() }
        let db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let healthStore = ProxyHealthStore()
        let coordinator = SSHProxyCoordinator(
            cliService: PassCLIService(cliPath: "/fake/pass-cli"),
            databaseManager: db,
            onError: { _ in },
            healthStore: healthStore,
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
            passCLIStatusStore: PassCLIStatusStore(),
            defaults: defaults
        )
        coordinator.lastEnabled = true
        healthStore.sshHealth = .unreachable(.cooldown)

        await coordinator.applySSHProbeResult(.healthy(identityCount: 3))

        #expect(healthStore.sshHealth == .ok(detail: "3 keys"))
    }

    @Test("startProxy resets state after daemon-start failure")
    func startProxyResetsStateAfterStartupFailure() async throws {
        defer { cleanup() }
        defaults.set(true, forKey: DefaultsKey.sshProxyEnabled)
        let (coordinator, errors) = try makeCoordinator()

        // Seed the authWindowController guard (L139) so startProxy() reaches
        // the first real failure site (daemon.startDaemon() with cliPath=/bin/false).
        let controllerDB = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let controller = SSHAuthWindowController(
            databaseManager: controllerDB,
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
            callbacks: .noop
        )
        coordinator.authWindowController = controller
        coordinator.lastEnabled = true

        await coordinator.startProxy()

        #expect(coordinator.proxy == nil)
        #expect(coordinator.daemonManager == nil)
        let firstError = try #require(errors.messages.first)
        #expect(firstError.contains("Failed to start SSH agent"))

        controller.cancelAll()
    }

    @Test("recoverProxyIfNeeded attempts restart after a prior startup failure")
    func recoverProxyIfNeededAttemptsAfterStartupFailure() async throws {
        defer { cleanup() }
        defaults.set(true, forKey: DefaultsKey.sshProxyEnabled)
        let (coordinator, _) = try makeCoordinator()

        let controllerDB = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let controller = SSHAuthWindowController(
            databaseManager: controllerDB,
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
            callbacks: .noop
        )
        coordinator.authWindowController = controller
        coordinator.lastEnabled = true

        // Drive startProxy into its daemon-start failure path.
        await coordinator.startProxy()

        // Seed a stale autoHeal failure; recoverProxyIfNeeded must reset it,
        // which is the observable signal that the restart path ran instead of
        // short-circuiting on a leaked proxy != nil reference.
        _ = coordinator.autoHeal.recordFailure(now: Date())

        let attempted = await coordinator.recoverProxyIfNeeded()

        #expect(attempted == true)
        #expect(coordinator.autoHeal.consecutiveFailures == 0)
        #expect(coordinator.autoHeal.lastRestartAt == nil)

        controller.cancelAll()
    }
}

@Suite("SSHProxyCoordinator.shouldFlipSSHHealthLabelOnCLIRecovery")
struct SSHProxyCoordinatorLabelFlipTests {
    @Test(arguments: [
        ProxyHealthState.unreachable(.passCLINotLoggedIn),
        ProxyHealthState.unreachable(.passCLIFailed("Command is not logout there is no session")),
    ])
    func flipsLoginDerivedState(current: ProxyHealthState) {
        #expect(SSHProxyCoordinator.shouldFlipSSHHealthLabelOnCLIRecovery(current))
    }

    @Test(arguments: [
        ProxyHealthState.ok(),
        ProxyHealthState.ok(detail: "2 keys"),
        ProxyHealthState.disabled,
        ProxyHealthState.degraded(.probeFailed),
        ProxyHealthState.degraded(.emptyIdentities),
        ProxyHealthState.degraded(.clientLoopFailure),
        ProxyHealthState.unreachable(.cooldown),
        ProxyHealthState.unreachable(.probeFailed),
        ProxyHealthState.unreachable(.emptyIdentities),
        ProxyHealthState.unreachable(.clientLoopFailure),
    ])
    func doesNotFlipOtherStates(current: ProxyHealthState) {
        #expect(SSHProxyCoordinator.shouldFlipSSHHealthLabelOnCLIRecovery(current) == false)
    }
}
