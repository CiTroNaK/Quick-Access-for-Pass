import AppKit
import Foundation

protocol URLOpening: Sendable {
    nonisolated func open(_ url: URL) async -> Bool
}

nonisolated struct WorkspaceURLOpener: URLOpening {
    nonisolated func open(_ url: URL) async -> Bool {
        await MainActor.run { NSWorkspace.shared.open(url) }
    }
}

protocol PassCLIHealthRefreshing: Sendable {
    nonisolated func refreshPassCLIHealth() async -> PassCLIHealth
}

nonisolated enum PassCLILoginState: Sendable, Equatable {
    case idle
    case waitingForURL
    case waitingForBrowser
    case succeeded
    case failed(String)
}

nonisolated enum PassCLILoginResult: Sendable, Equatable {
    case succeeded
    case failed(String)
}

@MainActor
final class PassCLILoginCoordinator {
    private let cliService: PassCLIService
    private let runner: any CLIStreaming
    private let urlOpener: any URLOpening
    private let healthRefresher: any PassCLIHealthRefreshing
    private let syncTrigger: @MainActor @Sendable () async -> Void
    private let resultHandler: @MainActor @Sendable (PassCLILoginResult) -> Void
    private let urlDiscoveryTimeout: Duration
    private let loginCompletionTimeout: Duration

    private var loginTask: Task<Void, Never>?
    private var currentProcess: CLIStreamingProcess?
    private var knownURL: URL?

    private(set) var state: PassCLILoginState = .idle

    init(
        cliService: PassCLIService,
        runner: any CLIStreaming = LiveCLIStreamingRunner(),
        urlOpener: any URLOpening = WorkspaceURLOpener(),
        healthRefresher: any PassCLIHealthRefreshing,
        syncTrigger: @escaping @MainActor @Sendable () async -> Void,
        resultHandler: @escaping @MainActor @Sendable (PassCLILoginResult) -> Void,
        urlDiscoveryTimeout: Duration = .seconds(15),
        loginCompletionTimeout: Duration = .seconds(300)
    ) {
        self.cliService = cliService
        self.runner = runner
        self.urlOpener = urlOpener
        self.healthRefresher = healthRefresher
        self.syncTrigger = syncTrigger
        self.resultHandler = resultHandler
        self.urlDiscoveryTimeout = urlDiscoveryTimeout
        self.loginCompletionTimeout = loginCompletionTimeout
    }

    func startLogin() {
        if let knownURL, loginTask != nil {
            Task { [urlOpener] in _ = await urlOpener.open(knownURL) }
            return
        }
        guard loginTask == nil else { return }
        loginTask = Task { @MainActor [weak self] in
            await self?.runLoginFlow()
        }
    }

    func waitForCurrentLogin() async {
        await loginTask?.value
    }

    func cancel() {
        currentProcess?.terminate()
        loginTask?.cancel()
        loginTask = nil
        currentProcess = nil
        knownURL = nil
        state = .idle
    }

    private func runLoginFlow() async {
        state = .waitingForURL
        defer {
            loginTask = nil
            currentProcess = nil
            knownURL = nil
        }

        do {
            let process = try runner.start(
                executablePath: cliService.cliPath,
                arguments: ["login"],
                capturePolicy: .redacted(PassCLILoginParser.redactedForCapture)
            )
            currentProcess = process

            let url = try await waitForLoginURL(in: process)
            knownURL = url
            state = .waitingForBrowser

            guard await urlOpener.open(url) else {
                process.terminate()
                fail("Could not open Proton login URL")
                return
            }

            let result = try await waitForCompletion(process)
            guard result.succeeded else {
                let diagnostic = result.stderr.isEmpty ? result.stdout : result.stderr
                let message = PassCLILoginParser.sanitizedMessage(from: diagnostic)
                fail(message.isEmpty ? "pass-cli login failed" : message)
                return
            }

            let health = await healthRefresher.refreshPassCLIHealth()
            guard health == .ok else {
                fail("Login finished, but Pass CLI is still not connected")
                return
            }

            state = .succeeded
            resultHandler(.succeeded)
            await syncTrigger()
        } catch is CancellationError {
            currentProcess?.terminate()
        } catch LoginFlowError.urlNotFound {
            currentProcess?.terminate()
            fail("The pass-cli login URL could not be found")
        } catch LoginFlowError.loginTimedOut {
            currentProcess?.terminate()
            fail("Login timed out before browser authentication completed")
        } catch {
            fail(PassCLILoginParser.sanitizedMessage(from: error.localizedDescription))
        }
    }

    private func fail(_ message: String) {
        let sanitized = PassCLILoginParser.sanitizedMessage(from: message)
        state = .failed(sanitized)
        resultHandler(.failed(sanitized))
    }
}

private enum LoginFlowError: Error, Equatable {
    case urlNotFound
    case loginTimedOut
}

private extension PassCLILoginCoordinator {
    func waitForLoginURL(in process: CLIStreamingProcess) async throws -> URL {
        let timeout = urlDiscoveryTimeout
        return try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask {
                var output = ""
                for try await chunk in process.chunks {
                    switch chunk {
                    case .stdout(let text), .stderr(let text):
                        output += text
                    }
                    if let url = PassCLILoginParser.authenticationURL(in: output) { return url }
                    output = String(output.suffix(8_000))
                }
                throw LoginFlowError.urlNotFound
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw LoginFlowError.urlNotFound
            }

            guard let url = try await group.next() else { throw LoginFlowError.urlNotFound }
            group.cancelAll()
            return url
        }
    }

    func waitForCompletion(_ process: CLIStreamingProcess) async throws -> CLIStreamingResult {
        let timeout = loginCompletionTimeout
        return try await withThrowingTaskGroup(of: CLIStreamingResult.self) { group in
            group.addTask { try await process.completion.value }
            group.addTask {
                try await Task.sleep(for: timeout)
                process.terminate()
                throw LoginFlowError.loginTimedOut
            }

            guard let result = try await group.next() else { throw LoginFlowError.loginTimedOut }
            group.cancelAll()
            return result
        }
    }
}
