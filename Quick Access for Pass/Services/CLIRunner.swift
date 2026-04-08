import Foundation

/// Abstracts CLI execution so health-check code can be tested with a fake.
protocol CLIRunning: Sendable {
    func run(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> Data
}

/// Production-grade CLIRunning that delegates to the existing CLIRunner.run static.
nonisolated struct LiveCLIRunner: CLIRunning {
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
}

/// Shared utility for running CLI processes with concurrent pipe reading and timeout handling.
/// Used by both `PassCLIService` and `SSHAgentDaemonManager` to avoid duplicated process setup.
nonisolated enum CLIRunner {

    /// Runs an executable with the given arguments and returns stdout data.
    /// Throws `CLIError` on failure, timeout, or if the executable is not found.
    static func run(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval = 300
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                var env = ProcessInfo.processInfo.environment
                env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin"
                process.environment = env

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: CLIError.notInstalled)
                    return
                }

                // Read both pipes concurrently to avoid deadlock
                // (if pipe buffer fills, process blocks on write, waitUntilExit never returns).
                // Each variable is written by exactly one GCD block; group.wait() synchronizes.
                nonisolated(unsafe) var outputData = Data()
                nonisolated(unsafe) var errorData = Data()
                let group = DispatchGroup()

                group.enter()
                DispatchQueue.global().async {
                    outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                group.enter()
                DispatchQueue.global().async {
                    errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                let result = group.wait(timeout: .now() + timeout)

                if result == .timedOut {
                    process.terminate()
                    process.waitUntilExit()
                    try? stdoutPipe.fileHandleForReading.close()
                    try? stderrPipe.fileHandleForReading.close()
                    _ = group.wait(timeout: .now() + 0.2)
                    continuation.resume(throwing: CLIError.timeout)
                    return
                }

                process.waitUntilExit()

                let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

                if process.terminationStatus == 0 {
                    let resultData = outputData
                    outputData.resetBytes(in: 0..<outputData.count)
                    errorData.resetBytes(in: 0..<errorData.count)
                    continuation.resume(returning: resultData)
                } else if Self.stderrIndicatesNotLoggedIn(errorOutput) {
                    outputData.resetBytes(in: 0..<outputData.count)
                    errorData.resetBytes(in: 0..<errorData.count)
                    continuation.resume(throwing: CLIError.notLoggedIn)
                } else {
                    outputData.resetBytes(in: 0..<outputData.count)
                    errorData.resetBytes(in: 0..<errorData.count)
                    continuation.resume(throwing: CLIError.commandFailed(errorOutput))
                }
            }
        }
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
    static func stderrIndicatesNotLoggedIn(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("not logged in")
            || lowered.contains("please log in")
            || lowered.contains("there is no session")
    }
}
