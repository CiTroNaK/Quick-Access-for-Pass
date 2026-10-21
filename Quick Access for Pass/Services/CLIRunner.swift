import Foundation
import os

/// Abstracts CLI execution so health-check code can be tested with a fake.
nonisolated protocol CLIRunning: Sendable {
    func run(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> Data
}

/// Abstracts CLI execution for commands that need controlled child-process
/// environment values. Used by PAT login so the token never becomes an
/// argument, UserDefault, or database value.
nonisolated protocol CLIEnvironmentRunning: Sendable {
    func run(
        executablePath: String,
        arguments: [String],
        environmentOverrides: [String: String],
        timeout: TimeInterval
    ) async throws -> Data
}

/// Production-grade CLIRunning that delegates to the existing CLIRunner.run static.
nonisolated struct LiveCLIRunner: CLIRunning, CLIEnvironmentRunning {
    nonisolated func run(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> Data {
        try await CLIRunner.run(
            executablePath: executablePath,
            arguments: arguments,
            timeout: timeout
        )
    }

    nonisolated func run(
        executablePath: String,
        arguments: [String],
        environmentOverrides: [String: String],
        timeout: TimeInterval
    ) async throws -> Data {
        try await CLIRunner.run(
            executablePath: executablePath,
            arguments: arguments,
            environmentOverrides: environmentOverrides,
            timeout: timeout
        )
    }
}

/// Shared utility for running CLI processes with concurrent pipe reading and timeout handling.
/// Used by both `PassCLIService` and `SSHAgentDaemonManager` to avoid duplicated process setup.
nonisolated enum CLIRunner {

    /// Runs an executable with the given arguments and returns stdout data.
    /// Throws `CLIError` on failure, timeout, or if the executable is not found.
    static func run(
        executablePath: String,
        arguments: [String],
        environmentOverrides: [String: String] = [:],
        timeout: TimeInterval = 300
    ) async throws -> Data {
        let cancellationState = ProcessCancellationState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    Self.execute(
                        configuration: ExecutionConfiguration(
                            executablePath: executablePath,
                            arguments: arguments,
                            environmentOverrides: environmentOverrides,
                            timeout: timeout
                        ),
                        cancellationState: cancellationState
                    ) { result in
                        continuation.resume(with: result)
                    }
                }
            }
        } onCancel: {
            cancellationState.cancel()
        }
    }

    private struct ExecutionConfiguration: Sendable {
        let executablePath: String
        let arguments: [String]
        let environmentOverrides: [String: String]
        let timeout: TimeInterval
    }

    private static func execute(
        configuration: ExecutionConfiguration,
        cancellationState: ProcessCancellationState,
        completion: @Sendable (Result<Data, Error>) -> Void
    ) {
        let processConfiguration = Self.configureProcess(
            executablePath: configuration.executablePath,
            arguments: configuration.arguments,
            environmentOverrides: configuration.environmentOverrides
        )
        let process = processConfiguration.process

        do {
            let pipeDrainer = try Self.startProcess(
                process: process,
                stdout: processConfiguration.stdout,
                stderr: processConfiguration.stderr,
                cancellationState: cancellationState
            )
            guard pipeDrainer.wait(timeout: configuration.timeout) else {
                Self.terminateAndDrain(process: process, pipeDrainer: pipeDrainer)
                throw cancellationState.finish() ? CancellationError() : CLIError.timeout
            }

            process.waitUntilExit()
            var pipeData = pipeDrainer.data()
            defer {
                Self.zero(&pipeData.stdout)
                Self.zero(&pipeData.stderr)
                pipeDrainer.zero()
            }

            guard cancellationState.finish() == false else {
                throw CancellationError()
            }
            completion(.success(try Self.result(
                for: process,
                stdout: pipeData.stdout,
                stderr: pipeData.stderr
            )))
        } catch {
            completion(.failure(error))
        }
    }

    private static func startProcess(
        process: Process,
        stdout: Pipe,
        stderr: Pipe,
        cancellationState: ProcessCancellationState
    ) throws -> PipeDrainer {
        guard cancellationState.begin(process: process) else {
            throw CancellationError()
        }
        do {
            try process.run()
        } catch {
            throw cancellationState.finish() ? CancellationError() : CLIError.notInstalled
        }
        if cancellationState.isCancelled, process.isRunning {
            process.terminate()
        }
        return PipeDrainer(stdout: stdout, stderr: stderr)
    }

    private static func configureProcess(
        executablePath: String,
        arguments: [String],
        environmentOverrides: [String: String]
    ) -> (process: Process, stdout: Pipe, stderr: Pipe) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = environment(overrides: environmentOverrides)
        return (process, stdout, stderr)
    }

    private static func terminateAndDrain(process: Process, pipeDrainer: PipeDrainer) {
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        pipeDrainer.closePipes()
        _ = pipeDrainer.wait(timeout: 0.2)
        pipeDrainer.zero()
    }

    private static func result(for process: Process, stdout: Data, stderr: Data) throws -> Data {
        let errorOutput = String(data: stderr, encoding: .utf8) ?? ""
        if process.terminationStatus == 0 {
            return stdout
        }
        if Self.stderrIndicatesNotLoggedIn(errorOutput) {
            throw CLIError.notLoggedIn
        }
        throw CLIError.commandFailed(errorOutput)
    }

    private static func zero(_ data: inout Data) {
        data.resetBytes(in: 0..<data.count)
    }

    private final class ProcessCancellationState: Sendable {
        private let lock = OSAllocatedUnfairLock(
            initialState: (process: Optional<Process>.none, isCancelled: false)
        )

        func begin(process: Process) -> Bool {
            lock.withLock { state in
                guard state.isCancelled == false else { return false }
                state.process = process
                return true
            }
        }

        var isCancelled: Bool {
            lock.withLock(\.isCancelled)
        }

        func finish() -> Bool {
            lock.withLock { state in
                state.process = nil
                return state.isCancelled
            }
        }

        func cancel() {
            lock.withLock { state in
                state.isCancelled = true
                if state.process?.isRunning == true {
                    state.process?.terminate()
                }
            }
        }
    }

    private final class PipeDrainer: Sendable {
        private let group = DispatchGroup()
        private let pipes: (stdout: Pipe, stderr: Pipe)
        private let dataLock = OSAllocatedUnfairLock(
            initialState: (stdout: Data(), stderr: Data(), discardsLateData: false)
        )

        init(stdout: Pipe, stderr: Pipe) {
            pipes = (stdout, stderr)

            group.enter()
            DispatchQueue.global().async { [self] in
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                dataLock.withLock { state in
                    guard state.discardsLateData == false else {
                        var discardedData = data
                        CLIRunner.zero(&discardedData)
                        return
                    }
                    state.stdout = data
                }
                group.leave()
            }

            group.enter()
            DispatchQueue.global().async { [self] in
                let data = stderr.fileHandleForReading.readDataToEndOfFile()
                dataLock.withLock { state in
                    guard state.discardsLateData == false else {
                        var discardedData = data
                        CLIRunner.zero(&discardedData)
                        return
                    }
                    state.stderr = data
                }
                group.leave()
            }
        }

        func wait(timeout: TimeInterval) -> Bool {
            group.wait(timeout: .now() + timeout) == .success
        }

        func closePipes() {
            try? pipes.stdout.fileHandleForReading.close()
            try? pipes.stderr.fileHandleForReading.close()
        }

        func data() -> (stdout: Data, stderr: Data) {
            dataLock.withLock { state in
                (state.stdout, state.stderr)
            }
        }

        func zero() {
            dataLock.withLock {
                $0.discardsLateData = true
                CLIRunner.zero(&$0.stdout)
                CLIRunner.zero(&$0.stderr)
            }
        }
    }

    private static func environment(overrides: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin"
        for (key, value) in overrides {
            env[key] = value
        }
        return env
    }

    /// Exact-phrase check for pass-cli's logged-out stderr. Prior substring
    /// matching on "session" and "auth" misclassified unrelated transients
    /// (e.g. "session expired during sync") as auth errors, so the allowed
    /// phrases here are intentionally narrow.
    ///
    /// Recognized:
    /// - `"not logged in"` (pre-2.x wording)
    /// - `"please log in"` (pre-2.x wording)
    /// - `"there is no session"` (pass-cli 2.x, emitted from
    ///    `pass-cli/src/main.rs:301` when any non-logout command is run
    ///    while no session exists)
    /// - `"failed to authenticate: non-existent session"` (a locally cached
    ///    session that can no longer authenticate requests)
    static func stderrIndicatesNotLoggedIn(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("not logged in")
            || lowered.contains("please log in")
            || lowered.contains("there is no session")
            || lowered.contains("failed to authenticate: non-existent session")
    }
}
