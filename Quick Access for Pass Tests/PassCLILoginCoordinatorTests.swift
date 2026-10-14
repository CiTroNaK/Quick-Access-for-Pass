import Foundation
import os
import Testing
@testable import Quick_Access_for_Pass

private struct FakeURLOpener: URLOpening {
    let opened: OpenedURLs

    nonisolated func open(_ url: URL) async -> Bool {
        await opened.append(url)
        return true
    }
}

private actor OpenedURLs {
    private var urls: [URL] = []

    func append(_ url: URL) {
        urls.append(url)
    }

    func count() -> Int {
        urls.count
    }
}

private actor SyncRecorder {
    private var syncCount = 0

    func sync() {
        syncCount += 1
    }

    func count() -> Int {
        syncCount
    }
}

private struct FakeHealthRefresher: PassCLIHealthRefreshing {
    let health: PassCLIHealth

    nonisolated func refreshPassCLIHealth() async -> PassCLIHealth {
        health
    }
}

private nonisolated final class FakeStreamingRunner: CLIStreaming, @unchecked Sendable {
    private struct State {
        var process: CLIStreamingProcess?
        var startCount = 0
        var executablePaths: [String] = []
        var startWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func setProcess(_ process: CLIStreamingProcess) {
        state.withLock { $0.process = process }
    }

    var startCount: Int {
        state.withLock { $0.startCount }
    }

    var executablePaths: [String] {
        state.withLock { $0.executablePaths }
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state in
                if state.startCount > 0 { return true }
                state.startWaiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    nonisolated func start(
        executablePath: String,
        arguments: [String],
        capturePolicy: CLIOutputCapturePolicy
    ) throws -> CLIStreamingProcess {
        let result = state.withLock { state -> Result<(CLIStreamingProcess, [CheckedContinuation<Void, Never>]), Error> in
            state.startCount += 1
            state.executablePaths.append(executablePath)
            let waiters = state.startWaiters
            state.startWaiters.removeAll()
            guard let process = state.process else {
                return .failure(CLIError.commandFailed("missing fake process"))
            }
            return .success((process, waiters))
        }

        switch result {
        case .success(let (process, waiters)):
            for waiter in waiters { waiter.resume() }
            return process
        case .failure(let error):
            throw error
        }
    }
}

private actor SessionResetRunner: CLIRunning {
    struct Invocation: Sendable, Equatable {
        let path: String
        let arguments: [String]
    }
    var invocations: [Invocation] = []
    var failure: CLIError?
    private var shouldPause = false
    private var resume: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?

    func configure(failure: CLIError? = nil, pause: Bool = false) {
        self.failure = failure
        shouldPause = pause
    }

    func waitUntilEntered() async {
        guard invocations.isEmpty else { return }
        await withCheckedContinuation { entered = $0 }
    }

    func finish() {
        resume?.resume()
        resume = nil
    }

    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        invocations.append(Invocation(path: executablePath, arguments: arguments))
        if shouldPause {
            await withCheckedContinuation { continuation in
                resume = continuation
                entered?.resume()
                entered = nil
            }
        }
        if let failure { throw failure }
        return Data()
    }
}

private actor TerminationRecorder {
    private var terminated = false

    func markTerminated() {
        terminated = true
    }

    func didTerminate() -> Bool {
        terminated
    }
}

private func fakeProcess(
    chunks: [CLIStreamChunk],
    result: CLIStreamingResult,
    terminated: TerminationRecorder? = nil
) -> CLIStreamingProcess {
    let stream = AsyncThrowingStream<CLIStreamChunk, Error> { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
    }
    let completion = Task<CLIStreamingResult, Error> { result }
    return CLIStreamingProcess(
        chunks: stream,
        completion: completion,
        terminate: { if let terminated { Task { await terminated.markTerminated() } } }
    )
}

@MainActor
struct PassCLILoginCoordinatorTests {
    @Test(.timeLimit(.minutes(1)))
    func unreadableSessionIsNotMisreportedAsMissingBrowserURL() async {
        let opened = OpenedURLs()
        let sync = SyncRecorder()
        let runner = FakeStreamingRunner()
        runner.setProcess(fakeProcess(
            chunks: [.stderr("Error getting client: Error decrypting local session(Error decrypting session: aead::Error)")],
            result: CLIStreamingResult(terminationStatus: 1, stdout: "", stderr: "Error decrypting local session")
        ))
        let coordinator = PassCLILoginCoordinator(
            cliService: PassCLIService(cliPath: "/fake/pass-cli"),
            runner: runner,
            urlOpener: FakeURLOpener(opened: opened),
            healthRefresher: FakeHealthRefresher(health: .localSessionUnreadable),
            syncTrigger: { await sync.sync() },
            resultHandler: { _ in },
            urlDiscoveryTimeout: .milliseconds(500)
        )

        coordinator.startLogin()
        await coordinator.waitForCurrentLogin()

        #expect(coordinator.state != .failed("The pass-cli login URL could not be found"))
        #expect(await opened.count() == 0)
        #expect(await sync.count() == 0)
        #expect(runner.startCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func opensParsedURLRefreshesHealthAndSyncsWhenHealthy() async throws {
        let opened = OpenedURLs()
        let sync = SyncRecorder()
        let runner = FakeStreamingRunner()
        runner.setProcess(fakeProcess(
            chunks: [.stdout("https://account.proton.me/desktop/login?app=pass#payload=synthetic-test-payload\n")],
            result: CLIStreamingResult(terminationStatus: 0, stdout: "ok", stderr: "")
        ))
        let coordinator = PassCLILoginCoordinator(
            cliService: PassCLIService(cliPath: "/fake/pass-cli"),
            runner: runner,
            urlOpener: FakeURLOpener(opened: opened),
            healthRefresher: FakeHealthRefresher(health: .ok),
            syncTrigger: { await sync.sync() },
            resultHandler: { _ in },
            urlDiscoveryTimeout: .milliseconds(500),
            loginCompletionTimeout: .milliseconds(500)
        )

        coordinator.startLogin()
        await coordinator.waitForCurrentLogin()

        #expect(await opened.count() == 1)
        #expect(await sync.count() == 1)
        #expect(coordinator.state == .succeeded)
    }

    @Test(.timeLimit(.minutes(1)))
    func doesNotSyncWhenPostLoginHealthIsNotOk() async {
        let opened = OpenedURLs()
        let sync = SyncRecorder()
        let runner = FakeStreamingRunner()
        runner.setProcess(fakeProcess(
            chunks: [.stdout("https://account.proton.me/desktop/login?app=pass#payload=synthetic-test-payload\n")],
            result: CLIStreamingResult(terminationStatus: 0, stdout: "ok", stderr: "")
        ))
        let coordinator = PassCLILoginCoordinator(
            cliService: PassCLIService(cliPath: "/fake/pass-cli"),
            runner: runner,
            urlOpener: FakeURLOpener(opened: opened),
            healthRefresher: FakeHealthRefresher(health: .notLoggedIn),
            syncTrigger: { await sync.sync() },
            resultHandler: { _ in },
            urlDiscoveryTimeout: .milliseconds(500),
            loginCompletionTimeout: .milliseconds(500)
        )

        coordinator.startLogin()
        await coordinator.waitForCurrentLogin()

        #expect(await opened.count() == 1)
        #expect(await sync.count() == 0)
        if case .failed(let message) = coordinator.state {
            #expect(message.contains("still not connected"))
        } else {
            Issue.record("Expected failed state after unhealthy refresh")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func duplicateLoginRequestDoesNotStartSecondProcessWhileFirstIsRunning() async throws {
        let runner = FakeStreamingRunner()
        let completionBox = CompletionBox()
        runner.setProcess(completionBox.makeProcessWithURL())
        let coordinator = PassCLILoginCoordinator(
            cliService: PassCLIService(cliPath: "/fake/pass-cli"),
            runner: runner,
            urlOpener: FakeURLOpener(opened: OpenedURLs()),
            healthRefresher: FakeHealthRefresher(health: .ok),
            syncTrigger: {},
            resultHandler: { _ in },
            urlDiscoveryTimeout: .milliseconds(500),
            loginCompletionTimeout: .seconds(5)
        )

        coordinator.startLogin()
        await runner.waitUntilStarted()
        coordinator.startLogin()

        #expect(runner.startCount == 1)
        completionBox.finishSuccessfully()
        await coordinator.waitForCurrentLogin()
    }
}

@MainActor
struct PassCLIBrowserSessionRepairTests {
    private func makeCoordinator(
        runner: FakeStreamingRunner,
        resetRunner: SessionResetRunner,
        cliService: PassCLIService = PassCLIService(cliPath: "/fake/pass-cli"),
        opened: OpenedURLs = OpenedURLs(),
        sync: SyncRecorder = SyncRecorder(),
        revoke: @escaping @MainActor @Sendable () -> Void = {}
    ) -> PassCLILoginCoordinator {
        PassCLILoginCoordinator(
            cliService: cliService,
            runner: runner,
            sessionResetRunner: resetRunner,
            urlOpener: FakeURLOpener(opened: opened),
            healthRefresher: FakeHealthRefresher(health: .ok),
            syncTrigger: { await sync.sync() },
            resultHandler: { _ in },
            revokeTransientSecretAccess: revoke,
            urlDiscoveryTimeout: .milliseconds(500),
            loginCompletionTimeout: .milliseconds(500)
        )
    }

    private func successfulRunner() -> FakeStreamingRunner {
        let runner = FakeStreamingRunner()
        runner.setProcess(fakeProcess(
            chunks: [.stdout("https://account.proton.me/desktop/login?app=pass#payload=synthetic-test-payload\n")],
            result: CLIStreamingResult(terminationStatus: 0, stdout: "", stderr: "")
        ))
        return runner
    }

    @Test(.timeLimit(.minutes(1)))
    func decliningRepairDoesNotRunCLIOrRevokeSecretAccess() async {
        let runner = successfulRunner()
        let reset = SessionResetRunner()
        let release = SecretReleaseGuard()
        let token = release.capture()
        let coordinator = makeCoordinator(runner: runner, resetRunner: reset, revoke: { release.revoke() })

        coordinator.requestLogin(health: .localSessionUnreadable, confirmSessionReset: { false })
        await coordinator.waitForCurrentLogin()

        #expect(await reset.invocations.isEmpty)
        #expect(runner.startCount == 0)
        #expect(release.isCurrent(token))
        #expect(coordinator.state == .idle)
    }

    @Test(.timeLimit(.minutes(1)))
    func confirmedRepairRevokesBeforeCleanupAndStartsOneBrowserLogin() async {
        let runner = successfulRunner()
        let reset = SessionResetRunner()
        await reset.configure(pause: true)
        let opened = OpenedURLs()
        let sync = SyncRecorder()
        let release = SecretReleaseGuard()
        let token = release.capture()
        let cliService = PassCLIService(cliPath: "/fake/pass-cli")
        let coordinator = makeCoordinator(
            runner: runner, resetRunner: reset, cliService: cliService,
            opened: opened, sync: sync, revoke: { release.revoke() }
        )

        coordinator.requestLogin(health: .localSessionUnreadable, confirmSessionReset: { true })
        await reset.waitUntilEntered()
        #expect(release.isCurrent(token) == false)
        #expect(runner.startCount == 0)
        cliService.updateCLIPath("/different/pass-cli")
        coordinator.requestLogin(health: .localSessionUnreadable, confirmSessionReset: {
            Issue.record("Duplicate request must not ask for another reset")
            return true
        })
        await reset.finish()
        await coordinator.waitForCurrentLogin()

        #expect(await reset.invocations == [.init(path: "/fake/pass-cli", arguments: ["logout", "--force"])])
        #expect(runner.startCount == 1)
        #expect(await opened.count() == 1)
        #expect(await sync.count() == 1)
        #expect(runner.executablePaths == ["/fake/pass-cli"])
        #expect(coordinator.state == .succeeded)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [CLIError.timeout, .commandFailed("private cleanup diagnostic")])
    func failedCleanupDoesNotStartBrowserLogin(error: CLIError) async {
        let runner = successfulRunner()
        let reset = SessionResetRunner()
        await reset.configure(failure: error)
        let sync = SyncRecorder()
        let coordinator = makeCoordinator(runner: runner, resetRunner: reset, sync: sync)

        coordinator.requestLogin(health: .localSessionUnreadable, confirmSessionReset: { true })
        await coordinator.waitForCurrentLogin()

        #expect(runner.startCount == 0)
        #expect(await sync.count() == 0)
        guard case .failed(let message) = coordinator.state else {
            Issue.record("Expected cleanup failure")
            return
        }
        #expect(message.contains("reset"))
        #expect(message.contains("private cleanup diagnostic") == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationDuringCleanupBlocksLoginAndOverlappingRepair() async {
        let runner = successfulRunner()
        let reset = SessionResetRunner()
        await reset.configure(pause: true)
        let coordinator = makeCoordinator(runner: runner, resetRunner: reset)
        coordinator.requestLogin(health: .localSessionUnreadable, confirmSessionReset: { true })
        await reset.waitUntilEntered()

        coordinator.cancel()
        coordinator.requestLogin(health: .localSessionUnreadable, confirmSessionReset: {
            Issue.record("Cancelled operation must unwind before a new reset")
            return true
        })
        await reset.finish()
        await coordinator.waitForCurrentLogin()

        #expect(await reset.invocations.count == 1)
        #expect(runner.startCount == 0)
        #expect(coordinator.state == .idle)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationBeforeCleanupPreventsMutation() async {
        let runner = successfulRunner()
        let reset = SessionResetRunner()
        let release = SecretReleaseGuard()
        let token = release.capture()
        let coordinator = makeCoordinator(runner: runner, resetRunner: reset, revoke: { release.revoke() })
        coordinator.requestLogin(health: .localSessionUnreadable, confirmSessionReset: { true })
        coordinator.cancel()
        await coordinator.waitForCurrentLogin()

        #expect(await reset.invocations.isEmpty)
        #expect(release.isCurrent(token))
        #expect(runner.startCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingDuringConfirmationInvalidatesConsent() async {
        let runner = successfulRunner()
        let reset = SessionResetRunner()
        let coordinator = makeCoordinator(runner: runner, resetRunner: reset)
        coordinator.requestLogin(health: .localSessionUnreadable, confirmSessionReset: {
            coordinator.cancel()
            return true
        })
        await coordinator.waitForCurrentLogin()

        #expect(await reset.invocations.isEmpty)
        #expect(runner.startCount == 0)
        #expect(coordinator.state == .idle)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [PassCLIHealth.notLoggedIn, .ok, .failed(reason: "network unreachable")])
    func ordinaryLoginDoesNotAskToResetOrRunLogout(health: PassCLIHealth) async {
        let runner = successfulRunner()
        let reset = SessionResetRunner()
        let coordinator = makeCoordinator(runner: runner, resetRunner: reset)

        coordinator.requestLogin(health: health, confirmSessionReset: {
            Issue.record("Ordinary login must not offer session reset")
            return true
        })
        await coordinator.waitForCurrentLogin()

        #expect(await reset.invocations.isEmpty)
        #expect(runner.startCount == 1)
        #expect(coordinator.state == .succeeded)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [PassCLIHealth.ok, .notLoggedIn, .notInstalled, .failed(reason: "network error")])
    func historicalFailureDoesNotAuthorizeResetAfterHealthChanges(health: PassCLIHealth) async {
        let runner = FakeStreamingRunner()
        runner.setProcess(fakeProcess(
            chunks: [.stderr("Error decrypting local session")],
            result: CLIStreamingResult(terminationStatus: 1, stdout: "", stderr: "Error decrypting local session")
        ))
        let reset = SessionResetRunner()
        let coordinator = makeCoordinator(runner: runner, resetRunner: reset)
        coordinator.startLogin()
        await coordinator.waitForCurrentLogin()
        #expect(coordinator.state == .localSessionUnreadable)

        runner.setProcess(fakeProcess(
            chunks: [.stdout("https://account.proton.me/desktop/login?app=pass#payload=synthetic-test-payload\n")],
            result: CLIStreamingResult(terminationStatus: 0, stdout: "", stderr: "")
        ))
        coordinator.requestLogin(health: health, confirmSessionReset: {
            Issue.record("Old login failure must not authorize cleanup after health changes")
            return true
        })
        await coordinator.waitForCurrentLogin()

        #expect(await reset.invocations.isEmpty)
        #expect(runner.startCount == 2)
        #expect(coordinator.state == .succeeded)
    }

    @Test(.timeLimit(.minutes(1)))
    func unreadableRestartedLoginIsNotResetRecursively() async {
        let runner = FakeStreamingRunner()
        runner.setProcess(fakeProcess(
            chunks: [.stderr("Error decrypting local "), .stderr("session: aead::Error")],
            result: CLIStreamingResult(terminationStatus: 1, stdout: "", stderr: "Error decrypting local session")
        ))
        let reset = SessionResetRunner()
        let coordinator = makeCoordinator(runner: runner, resetRunner: reset)

        coordinator.requestLogin(health: .localSessionUnreadable, confirmSessionReset: { true })
        await coordinator.waitForCurrentLogin()

        #expect(await reset.invocations.count == 1)
        #expect(runner.startCount == 1)
        #expect(coordinator.state == .localSessionUnreadable)
    }
}

private nonisolated final class CompletionBox: @unchecked Sendable {
    private final class Storage: @unchecked Sendable {
        var continuation: CheckedContinuation<CLIStreamingResult, Never>?
    }

    private let storage = OSAllocatedUnfairLock(initialState: Storage())

    func makeProcessWithURL() -> CLIStreamingProcess {
        let stream = AsyncThrowingStream<CLIStreamChunk, Error> { continuation in
            continuation.yield(.stdout("https://account.proton.me/desktop/login?app=pass#payload=synthetic-test-payload\n"))
        }
        let completion = Task<CLIStreamingResult, Error> {
            await withCheckedContinuation { continuation in
                self.storage.withLock { $0.continuation = continuation }
            }
        }
        return CLIStreamingProcess(chunks: stream, completion: completion, terminate: {})
    }

    func finishSuccessfully() {
        let continuation = storage.withLock { storage in
            let continuation = storage.continuation
            storage.continuation = nil
            return continuation
        }
        continuation?.resume(returning: CLIStreamingResult(terminationStatus: 0, stdout: "", stderr: ""))
    }
}
