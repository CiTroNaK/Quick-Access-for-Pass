import Foundation

actor SSHAgentDaemonManager {
    nonisolated let cliPath: String
    nonisolated let upstreamSocketPath: String
    private let runner: any CLIRunning
    private let isSocketHealthy: @Sendable (String) async -> Bool
    private var daemonStartedByUs = false
    private var startInFlight: Task<Void, Error>?
    private var restartInFlight: Task<Void, Error>?

    init(
        cliPath: String,
        socketPath: String? = nil,
        runner: any CLIRunning = LiveCLIRunner(),
        isSocketHealthy: @escaping @Sendable (String) async -> Bool = SSHAgentDaemonManager.defaultSocketHealthCheck
    ) {
        self.cliPath = cliPath
        self.upstreamSocketPath = socketPath ??
            NSString(string: SSHAgentConstants.defaultUpstreamSocketPath).expandingTildeInPath
        self.runner = runner
        self.isSocketHealthy = isSocketHealthy
    }

    /// Cheap best-effort "already running?" check used only to avoid double-starting the daemon.
    /// This parses `pass-cli ssh-agent daemon status` text output and can be fooled by a stale
    /// PID file whose PID has been reused. `startDaemon(vaultNames:)` therefore confirms the
    /// socket responds before accepting this result.
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
            if await isDaemonRunning() {
                if await isSocketHealthy(upstreamSocketPath) { return }
                try clearStaleDaemonState()
            }
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

    private nonisolated static let defaultSocketHealthCheck: @Sendable (String) async -> Bool = { path in
        switch await SSHProxyProbe.listIdentities(at: path) {
        case .healthy, .emptyIdentities:
            true
        case .unreachable:
            false
        }
    }

    private func clearStaleDaemonState() throws {
        let fileManager = FileManager.default
        let pidPath = URL(fileURLWithPath: upstreamSocketPath)
            .deletingPathExtension()
            .appendingPathExtension("pid")
            .path
        for path in [upstreamSocketPath, pidPath] where fileManager.fileExists(atPath: path) {
            try fileManager.removeItem(atPath: path)
        }
    }

    private func runCLI(arguments: [String]) async throws -> Data {
        do {
            return try await runner.run(executablePath: cliPath, arguments: arguments, timeout: 30)
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
