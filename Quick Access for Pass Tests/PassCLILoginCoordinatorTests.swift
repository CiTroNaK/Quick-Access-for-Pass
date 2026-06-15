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
        var startWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func setProcess(_ process: CLIStreamingProcess) {
        state.withLock { $0.process = process }
    }

    var startCount: Int {
        state.withLock { $0.startCount }
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
