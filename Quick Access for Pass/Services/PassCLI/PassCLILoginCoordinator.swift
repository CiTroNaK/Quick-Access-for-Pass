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
    case resettingSession
    case waitingForURL
    case waitingForBrowser
    case localSessionUnreadable
    case succeeded
    case failed(String)
}

nonisolated enum PassCLILoginResult: Sendable, Equatable {
    case succeeded
    case localSessionUnreadable
    case failed(String)
}

@MainActor
final class PassCLILoginCoordinator {
    private let cliService: PassCLIService
    private let runner: any CLIStreaming
    private let sessionResetRunner: any CLIRunning
    private let revokeTransientSecretAccess: @MainActor @Sendable () -> Void
    private let urlOpener: any URLOpening
    private let healthRefresher: any PassCLIHealthRefreshing
    private let syncTrigger: @MainActor @Sendable () async -> Void
    private let resultHandler: @MainActor @Sendable (PassCLILoginResult) -> Void
    private let urlDiscoveryTimeout: Duration
    private let loginCompletionTimeout: Duration

    private var loginTask: Task<Void, Never>?
    private var currentProcess: CLIStreamingProcess?
    private var knownURL: URL?
    private var isConfirmingSessionReset = false
    private var confirmationGeneration = 0

    /// Whether confirmation or a login/reset process still owns this coordinator.
    var isLoggingIn: Bool { isConfirmingSessionReset || loginTask != nil }

    private(set) var state: PassCLILoginState = .idle

    init(
        cliService: PassCLIService,
        runner: any CLIStreaming = LiveCLIStreamingRunner(),
        sessionResetRunner: any CLIRunning = LiveCLIRunner(),
        urlOpener: any URLOpening = WorkspaceURLOpener(),
        healthRefresher: any PassCLIHealthRefreshing,
        syncTrigger: @escaping @MainActor @Sendable () async -> Void,
        resultHandler: @escaping @MainActor @Sendable (PassCLILoginResult) -> Void,
        revokeTransientSecretAccess: @escaping @MainActor @Sendable () -> Void = {},
        urlDiscoveryTimeout: Duration = .seconds(15),
        loginCompletionTimeout: Duration = .seconds(300)
    ) {
        self.cliService = cliService
        self.runner = runner
        self.sessionResetRunner = sessionResetRunner
        self.revokeTransientSecretAccess = revokeTransientSecretAccess
        self.urlOpener = urlOpener
        self.healthRefresher = healthRefresher
        self.syncTrigger = syncTrigger
        self.resultHandler = resultHandler
        self.urlDiscoveryTimeout = urlDiscoveryTimeout
        self.loginCompletionTimeout = loginCompletionTimeout
    }

    /// Requests browser login, requiring explicit consent before repairing an unreadable session.
    func requestLogin(health: PassCLIHealth, confirmSessionReset: @MainActor () -> Bool) {
        guard !isConfirmingSessionReset else { return }
        guard loginTask == nil else {
            startLogin()
            return
        }
        // Historical login outcomes are presentation, not current cleanup authority.
        guard health == .localSessionUnreadable else {
            startLogin()
            return
        }
        isConfirmingSessionReset = true
        defer { isConfirmingSessionReset = false }
        let generation = confirmationGeneration
        guard confirmSessionReset(), generation == confirmationGeneration, loginTask == nil else { return }
        enqueueLogin(resetLocalSession: true)
    }

    /// Starts ordinary browser login without resetting any existing session.
    func startLogin() {
        enqueueLogin(resetLocalSession: false)
    }

    private func enqueueLogin(resetLocalSession: Bool) {
        if let knownURL, loginTask != nil {
            Task { [urlOpener] in _ = await urlOpener.open(knownURL) }
            return
        }
        guard loginTask == nil else { return }
        loginTask = Task { @MainActor [weak self] in
            await self?.runLoginFlow(resetLocalSession: resetLocalSession)
        }
    }

    func waitForCurrentLogin() async {
        await loginTask?.value
    }

    func cancel() {
        currentProcess?.terminate()
        loginTask?.cancel()
        confirmationGeneration += 1
        // Keep ownership until the cancelled task unwinds; cleanup may still be
        // terminating, and a new request must not overlap session mutation.
        knownURL = nil
        state = .idle
    }

    private func runLoginFlow(resetLocalSession: Bool) async {
        let executablePath = cliService.cliPath
        defer {
            loginTask = nil
            currentProcess = nil
            knownURL = nil
        }

        do {
            try Task.checkCancellation()
            state = resetLocalSession ? .resettingSession : .waitingForURL
            if resetLocalSession {
                try await self.resetLocalSession(at: executablePath)
            }
            try Task.checkCancellation()
            state = .waitingForURL
            try await runBrowserLogin(executablePath: executablePath)
        } catch {
            handleLoginFailure(error)
        }
    }

    private func runBrowserLogin(executablePath: String) async throws {
        let process = try runner.start(
            executablePath: executablePath,
            arguments: ["login"],
            capturePolicy: .redacted(PassCLILoginParser.redactedForCapture)
        )
        currentProcess = process

        let url = try await waitForLoginURL(in: process)
        try Task.checkCancellation()
        knownURL = url
        state = .waitingForBrowser

        let opened = await urlOpener.open(url)
        try Task.checkCancellation()
        guard opened else {
            process.terminate()
            fail("Could not open Proton login URL")
            return
        }

        let result = try await waitForCompletion(process)
        try Task.checkCancellation()
        guard result.succeeded else {
            let diagnostic = result.stderr.isEmpty ? result.stdout : result.stderr
            if CLIError.commandFailed(diagnostic).isLocalSessionDecryptionError {
                throw LoginFlowError.localSessionUnreadable
            }
            let message = PassCLILoginParser.sanitizedMessage(from: diagnostic)
            fail(message.isEmpty ? "pass-cli login failed" : message)
            return
        }

        let health = await healthRefresher.refreshPassCLIHealth()
        try Task.checkCancellation()
        guard health == .ok else {
            fail("Login finished, but Pass CLI is still not connected")
            return
        }

        state = .succeeded
        resultHandler(.succeeded)
        await syncTrigger()
    }

    private func handleLoginFailure(_ error: any Error) {
        currentProcess?.terminate()
        guard !Task.isCancelled, !(error is CancellationError) else { return }
        switch error {
        case LoginFlowError.localSessionUnreadable:
            state = .localSessionUnreadable
            resultHandler(.localSessionUnreadable)
        case LoginFlowError.sessionResetFailed:
            fail(String(localized: "Could not reset the local CLI session. No browser login was started."))
        case LoginFlowError.urlNotFound:
            fail("The pass-cli login URL could not be found")
        case LoginFlowError.loginTimedOut:
            fail("Login timed out before browser authentication completed")
        default:
            fail(PassCLILoginParser.sanitizedMessage(from: error.localizedDescription))
        }
    }

    private func fail(_ message: String) {
        let sanitized = PassCLILoginParser.sanitizedMessage(from: message)
        state = .failed(sanitized)
        resultHandler(.failed(sanitized))
    }
}

private nonisolated enum LoginFlowError: Error, Equatable {
    case urlNotFound
    case loginTimedOut
    case localSessionUnreadable
    case sessionResetFailed
}

private extension PassCLILoginCoordinator {
    /// Delegates confirmed cleanup to the CLI, without direct file/key removal or offline-data purge.
    func resetLocalSession(at executablePath: String) async throws {
        try Task.checkCancellation()
        revokeTransientSecretAccess()
        do {
            _ = try await sessionResetRunner.run(
                executablePath: executablePath, arguments: ["logout", "--force"],
                timeout: 30, maximumOutputBytes: 8_192
            )
        } catch {
            try Task.checkCancellation()
            throw LoginFlowError.sessionResetFailed
        }
        try Task.checkCancellation()
    }

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
                    try Task.checkCancellation()
                    if CLIError.commandFailed(output).isLocalSessionDecryptionError {
                        throw LoginFlowError.localSessionUnreadable
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
