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
}
