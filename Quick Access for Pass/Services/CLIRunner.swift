import Darwin
import Foundation
import os

nonisolated enum CLIError: Error, LocalizedError {
    case notInstalled
    case notLoggedIn
    case commandFailed(String)
    case timeout
    case outputLimitExceeded
    case secretFetchFailed
    case parseError(String)

    var isNotInstalled: Bool { if case .notInstalled = self { return true }; return false }
    var isAuthError: Bool {
        switch self {
        case .notLoggedIn: true
        case .commandFailed(let message): CLIRunner.stderrIndicatesNotLoggedIn(message)
        default: false
        }
    }
    var errorDescription: String? {
        switch self {
        case .notInstalled: String(localized: "pass-cli is not installed. Instructionas at https://protonpass.github.io/pass-cli/")
        case .notLoggedIn: String(localized: "Pass CLI is logged out. Open Settings → Pass CLI to log in.")
        case .commandFailed(let message): String(localized: "pass-cli command failed: \(message)")
        case .timeout: String(localized: "pass-cli command timed out")
        case .outputLimitExceeded: String(localized: "pass-cli command produced too much output")
        case .secretFetchFailed: String(localized: "pass-cli could not retrieve the requested secret")
        case .parseError(let message): String(localized: "Failed to parse pass-cli output: \(message)")
        }
    }
}

nonisolated protocol CLIRunning: Sendable {
    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data
    func run(executablePath: String, arguments: [String], timeout: TimeInterval, maximumOutputBytes: Int) async throws -> Data
    func run(executablePath: String, arguments: [String], deadline: CLIExecutionDeadline, maximumOutputBytes: Int) async throws -> Data
}

extension CLIRunning {
    func run(executablePath: String, arguments: [String], deadline: CLIExecutionDeadline, maximumOutputBytes: Int) async throws -> Data {
        let remaining = try deadline.remainingSeconds(at: DispatchTime.now().uptimeNanoseconds)
        return try await run(executablePath: executablePath, arguments: arguments, timeout: remaining, maximumOutputBytes: maximumOutputBytes)
    }

    /// Fakes retain their old requirement but cannot bypass secret output limits.
    func run(executablePath: String, arguments: [String], timeout: TimeInterval, maximumOutputBytes: Int) async throws -> Data {
        let data = try await run(executablePath: executablePath, arguments: arguments, timeout: timeout)
        guard data.count <= maximumOutputBytes else { throw CLIError.outputLimitExceeded }
        return data
    }
}

nonisolated protocol CLIEnvironmentRunning: Sendable {
    func run(executablePath: String, arguments: [String], environmentOverrides: [String: String], timeout: TimeInterval) async throws -> Data
}

nonisolated struct LiveCLIRunner: CLIRunning, CLIEnvironmentRunning {
    nonisolated func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        try await CLIRunner.run(executablePath: executablePath, arguments: arguments, timeout: timeout)
    }

    nonisolated func run(executablePath: String, arguments: [String], timeout: TimeInterval, maximumOutputBytes: Int) async throws -> Data {
        try await CLIRunner.run(executablePath: executablePath, arguments: arguments, timeout: timeout, maximumOutputBytes: maximumOutputBytes)
    }

    nonisolated func run(executablePath: String, arguments: [String], deadline: CLIExecutionDeadline, maximumOutputBytes: Int) async throws -> Data {
        try await CLIRunner.run(executablePath: executablePath, arguments: arguments, deadline: deadline, maximumOutputBytes: maximumOutputBytes)
    }

    nonisolated func run(executablePath: String, arguments: [String], environmentOverrides: [String: String], timeout: TimeInterval) async throws -> Data {
        try await CLIRunner.run(executablePath: executablePath, arguments: arguments, environmentOverrides: environmentOverrides, timeout: timeout)
    }
}

/// A bounded, cancellation-aware native process lifecycle. Process ownership is
/// actor-isolated; pipe I/O is performed by Dispatch read sources on `ioQueue`.
nonisolated enum CLIRunner {
    /// Internal test-only lifecycle observation; it exposes no process IDs,
    /// descriptors, output, or secret material and is nil in production.
    typealias LifecycleTesting = CLIRunnerLifecycleTesting

    private static let stderrLimit = 256 * 1024

    static func run(
        executablePath: String, arguments: [String],
        environmentOverrides: [String: String] = [:], timeout: TimeInterval = 300
    ) async throws -> Data {
        try await runInternal(
            launch: LaunchInputs(executablePath: executablePath, arguments: arguments, environmentOverrides: environmentOverrides),
            timing: Timing(timeout: timeout, deadline: nil), maximumOutputBytes: nil, lifecycleTesting: nil
        )
    }

    static func run(executablePath: String, arguments: [String], timeout: TimeInterval, maximumOutputBytes: Int) async throws -> Data {
        try await runInternal(
            launch: LaunchInputs(executablePath: executablePath, arguments: arguments, environmentOverrides: [:]),
            timing: Timing(timeout: timeout, deadline: nil), maximumOutputBytes: maximumOutputBytes,
            lifecycleTesting: nil
        )
    }

    static func run(
        executablePath: String, arguments: [String], environmentOverrides: [String: String],
        deadline: CLIExecutionDeadline, maximumOutputBytes: Int
    ) async throws -> Data {
        try await run(
            executablePath: executablePath, arguments: arguments, environmentOverrides: environmentOverrides,
            deadline: deadline, maximumOutputBytes: maximumOutputBytes, lifecycleTesting: nil
        )
    }

    static func run(
        executablePath: String, arguments: [String], deadline: CLIExecutionDeadline,
        maximumOutputBytes: Int
    ) async throws -> Data {
        try await run(
            executablePath: executablePath, arguments: arguments, deadline: deadline,
            maximumOutputBytes: maximumOutputBytes, lifecycleTesting: nil
        )
    }

    static func run(
        executablePath: String, arguments: [String], environmentOverrides: [String: String] = [:],
        deadline: CLIExecutionDeadline, maximumOutputBytes: Int?, lifecycleTesting: LifecycleTesting?
    ) async throws -> Data {
        try await runInternal(
            launch: LaunchInputs(executablePath: executablePath, arguments: arguments, environmentOverrides: environmentOverrides),
            timing: Timing(timeout: nil, deadline: DispatchTime(uptimeNanoseconds: deadline.uptimeNanoseconds)),
            maximumOutputBytes: maximumOutputBytes, lifecycleTesting: lifecycleTesting
        )
    }

    static func run(
        executablePath: String, arguments: [String], environmentOverrides: [String: String],
        timeout: TimeInterval, maximumOutputBytes: Int?
    ) async throws -> Data {
        try await runInternal(
            launch: LaunchInputs(executablePath: executablePath, arguments: arguments, environmentOverrides: environmentOverrides),
            timing: Timing(timeout: timeout, deadline: nil), maximumOutputBytes: maximumOutputBytes,
            lifecycleTesting: nil
        )
    }

    static func run(
        executablePath: String,
        arguments: [String],
        environmentOverrides: [String: String] = [:],
        timeout: TimeInterval,
        maximumOutputBytes: Int?,
        lifecycleTesting: LifecycleTesting?
    ) async throws -> Data {
        try await runInternal(
            launch: LaunchInputs(executablePath: executablePath, arguments: arguments, environmentOverrides: environmentOverrides),
            timing: Timing(timeout: timeout, deadline: nil), maximumOutputBytes: maximumOutputBytes,
            lifecycleTesting: lifecycleTesting
        )
    }

    private struct LaunchInputs {
        let executablePath: String
        let arguments: [String]
        let environmentOverrides: [String: String]
    }

    private struct Timing {
        let timeout: TimeInterval?
        let deadline: DispatchTime?
    }

    private static func runInternal(
        launch: LaunchInputs,
        timing: Timing,
        maximumOutputBytes: Int?, lifecycleTesting: LifecycleTesting?
    ) async throws -> Data {
        let deadline: DispatchTime
        let timeout: TimeInterval
        if let absoluteDeadline = timing.deadline {
            deadline = absoluteDeadline
            timeout = (try? CLIExecutionDeadline(uptimeNanoseconds: absoluteDeadline.uptimeNanoseconds)
                .remainingSeconds(at: DispatchTime.now().uptimeNanoseconds)) ?? 0
        } else {
            timeout = timing.timeout ?? 300
            deadline = DispatchTime.now() + max(0, timeout)
        }
        // The shared absolute deadline bounds queueing, launch, and termination grace.
        lifecycleTesting?.marker(.deadlineCaptured)
        let cancellationState = CLIRunnerCancellationState()
        let ioQueue = DispatchQueue(label: "com.quickaccess.pass.cli.io")
        let ioExecutor = CLIRunnerTaskExecutor(
            queue: ioQueue, lifecycleTesting: lifecycleTesting, event: .ioExecutorJobStarted
        )
        let controlExecutor = CLIRunnerTaskExecutor(
            queue: DispatchQueue(label: "com.quickaccess.pass.cli.control"),
            lifecycleTesting: lifecycleTesting, event: .controlExecutorJobStarted
        )
        let execution = CLIExecution(
            executablePath: launch.executablePath, arguments: launch.arguments, environmentOverrides: launch.environmentOverrides,
            timeout: timeout, deadline: deadline, cancellationState: cancellationState,
            stdoutLimit: maximumOutputBytes, stderrLimit: maximumOutputBytes == nil ? nil : stderrLimit,
            lifecycleTesting: lifecycleTesting, ioQueue: ioQueue,
            controlExecutor: controlExecutor, ioExecutor: ioExecutor
        )
        return try await withTaskCancellationHandler {
            // Native startup uses the operation-owned control executor rather
            // than blocking or queueing on the caller's cooperative pool. The
            // structured group still joins startup and retains the original deadline.
            try await withThrowingTaskGroup(of: Void.self, returning: Data.self) { group in
                try await withCheckedThrowingContinuation { continuation in
                    group.addTask(executorPreference: controlExecutor) {
                        lifecycleTesting?.marker(.startTaskEntered)
                        if let suspension = lifecycleTesting?.suspension { await suspension(.beforeExecutionStart) }
                        await execution.start(continuation)
                    }
                }
            }
        } onCancel: {
            cancellationState.recordCancellation()
            Task(executorPreference: controlExecutor) {
                if let suspension = lifecycleTesting?.suspension { await suspension(.beforeCancellationCleanup) }
                await execution.cancel()
            }
        }
    }

    static func result(for process: Process, stdout: Data, stderr: Data) throws -> Data {
        if process.terminationStatus == 0 { return stdout }
        let errorOutput = String(data: stderr, encoding: .utf8) ?? ""
        if stderrIndicatesNotLoggedIn(errorOutput) { throw CLIError.notLoggedIn }
        throw CLIError.commandFailed(errorOutput)
    }

    static func zero(_ data: inout Data) {
        guard !data.isEmpty else { return }
        data.resetBytes(in: 0..<data.count)
    }

    static func environment(overrides: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin"
        for (key, value) in overrides { env[key] = value }
        return env
    }

    static func stderrIndicatesNotLoggedIn(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("not logged in") || lowered.contains("please log in")
            || lowered.contains("there is no session") || lowered.contains("failed to authenticate: non-existent session")
    }
}
