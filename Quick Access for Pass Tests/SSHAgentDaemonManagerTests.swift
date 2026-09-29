import Testing
import Foundation
@testable import Quick_Access_for_Pass

@Suite("SSHAgentDaemonManager Tests")
struct SSHAgentDaemonManagerTests {

    @Test func defaultSocketPath() {
        let manager = SSHAgentDaemonManager(cliPath: "/usr/bin/false")
        #expect(manager.upstreamSocketPath.hasSuffix("proton-pass-agent.sock"))
    }

    @Test func buildStartArguments() {
        let manager = SSHAgentDaemonManager(cliPath: "/opt/homebrew/bin/pass-cli")
        let args = manager.buildDaemonStartArguments(vaultNames: ["Personal", "Work"])
        #expect(args == ["ssh-agent", "daemon", "start", "--vault-name", "Personal", "--vault-name", "Work"])
    }

    @Test func buildStartArgumentsNoVaults() {
        let manager = SSHAgentDaemonManager(cliPath: "/opt/homebrew/bin/pass-cli")
        let args = manager.buildDaemonStartArguments(vaultNames: [])
        #expect(args == ["ssh-agent", "daemon", "start"])
    }

    @Test("stale reported daemon is cleared and started again")
    func startDaemonClearsStaleReportedDaemon() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let socketURL = directory.appendingPathComponent("proton-pass-agent.sock")
        let pidURL = directory.appendingPathComponent("proton-pass-agent.pid")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: socketURL)
        try Data("1280".utf8).write(to: pidURL)
        defer { try? FileManager.default.removeItem(at: directory) }

        let runner = DaemonCommandRecorder()
        let manager = SSHAgentDaemonManager(
            cliPath: "/fake/pass-cli",
            socketPath: socketURL.path,
            runner: runner,
            isSocketHealthy: { _ in false }
        )

        try await manager.startDaemon()

        #expect(FileManager.default.fileExists(atPath: socketURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: pidURL.path) == false)
        #expect(await runner.commands() == [
            ["ssh-agent", "daemon", "status"],
            ["ssh-agent", "daemon", "start"]
        ])
    }

    @Test("responsive reported daemon is not restarted")
    func startDaemonKeepsResponsiveReportedDaemon() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let socketURL = directory.appendingPathComponent("proton-pass-agent.sock")
        let pidURL = directory.appendingPathComponent("proton-pass-agent.pid")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: socketURL)
        try Data("53479".utf8).write(to: pidURL)
        defer { try? FileManager.default.removeItem(at: directory) }

        let runner = DaemonCommandRecorder()
        let manager = SSHAgentDaemonManager(
            cliPath: "/fake/pass-cli",
            socketPath: socketURL.path,
            runner: runner,
            isSocketHealthy: { _ in true }
        )

        try await manager.startDaemon()

        #expect(FileManager.default.fileExists(atPath: socketURL.path))
        #expect(FileManager.default.fileExists(atPath: pidURL.path))
        #expect(await runner.commands() == [["ssh-agent", "daemon", "status"]])
    }
}

private actor DaemonCommandRecorder: CLIRunning {
    private var recordedCommands: [[String]] = []

    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        recordedCommands.append(arguments)
        if arguments == ["ssh-agent", "daemon", "status"] {
            return Data("Status:   running\\n".utf8)
        }
        return Data()
    }

    func commands() -> [[String]] {
        recordedCommands
    }
}
