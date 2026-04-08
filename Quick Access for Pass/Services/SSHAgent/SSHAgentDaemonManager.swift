import Foundation

actor SSHAgentDaemonManager {
    nonisolated let cliPath: String
    nonisolated let upstreamSocketPath: String
    private var daemonStartedByUs = false
    private var startInFlight: Task<Void, Error>?
    private var restartInFlight: Task<Void, Error>?

    init(cliPath: String, socketPath: String? = nil) {
        self.cliPath = cliPath
        self.upstreamSocketPath = socketPath ??
            NSString(string: SSHAgentConstants.defaultUpstreamSocketPath).expandingTildeInPath
    }

    /// Cheap best-effort "already running?" check used only to avoid double-starting the daemon.
    /// This parses `pass-cli ssh-agent daemon status` text output and may be imprecise (stale
    /// pidfiles, etc.). Health decisions are NOT based on this — the probe in SSHProxyProbe
    /// is the source of truth for health state.
    func isDaemonRunning() async -> Bool {
        guard let output = try? await runCLI(arguments: ["ssh-agent", "daemon", "status"]),
              let text = String(data: output, encoding: .utf8) else { return false }
        return text.contains("Status:   running")
    }

    func startDaemon(vaultNames: [String] = []) async throws {
        if daemonStartedByUs { return }
        if let startInFlight {
            try await startInFlight.value
            return
        }
        let task = Task { [self] in
            if await isDaemonRunning() { return }
            let arguments = buildDaemonStartArguments(vaultNames: vaultNames)
            _ = try await runCLI(arguments: arguments)
            daemonStartedByUs = true
        }
        startInFlight = task
        defer { startInFlight = nil }
        try await task.value
    }

    func stopDaemon() async {
        guard daemonStartedByUs else { return }
        _ = try? await runCLI(arguments: ["ssh-agent", "daemon", "stop"])
        daemonStartedByUs = false
    }

    func restartDaemon(vaultNames: [String] = []) async throws {
        if let restartInFlight {
            try await restartInFlight.value
            return
        }
        let task = Task { [self] in
            if daemonStartedByUs {
                _ = try? await runCLI(arguments: ["ssh-agent", "daemon", "stop"])
            }
            let arguments = buildDaemonStartArguments(vaultNames: vaultNames)
            _ = try await runCLI(arguments: arguments)
            daemonStartedByUs = true
        }
        restartInFlight = task
        defer { restartInFlight = nil }
        try await task.value
    }

    nonisolated func buildDaemonStartArguments(vaultNames: [String]) -> [String] {
        var args = ["ssh-agent", "daemon", "start"]
        for name in vaultNames {
            args.append("--vault-name")
            args.append(name)
        }
        return args
    }

    private func runCLI(arguments: [String]) async throws -> Data {
        do {
            return try await CLIRunner.run(executablePath: cliPath, arguments: arguments, timeout: 30)
        } catch CLIError.commandFailed(let msg) {
            // Strip ANSI escape codes from pass-cli's colored output
            let cleaned = msg.replacingOccurrences(
                of: "\\x1B\\[[0-9;]*m",
                with: "",
                options: .regularExpression
            )
            throw CLIError.commandFailed(cleaned)
        }
    }
}
