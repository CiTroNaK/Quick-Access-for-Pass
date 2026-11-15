import Foundation
import Testing
@testable import Quick_Access_for_Pass

private let coreBundle = "/U/.local/share/herdr-core/active/Herdr Core.app"
private let holderPath = coreBundle + "/Contents/MacOS/herdr-core"
private let socket = "/U/.local/state/herdr-core/default/default.sock"

@Suite struct HerdrCoreTerminalResolverTests {
    private func node(_ pid: Int32, _ path: String, parent: Int32? = nil, start: UInt64? = nil) -> RequesterProcessSnapshot.ProcessNode {
        .init(pid: pid, parentPID: parent ?? pid + 1, startTimeMicroseconds: start ?? UInt64(pid),
              executablePath: path, canonicalExecutablePath: path)
    }
    private func hint(_ pid: Int32, terminal: String = "t5", start: UInt64? = nil) -> HerdrCoreRoutingHint {
        .init(terminalID: terminal, socketPath: socket, originatingPID: pid, originatingStartTimeMicroseconds: start ?? UInt64(pid))
    }
    private func client(bundleID: String? = "dev.herdr.core", bundleURL: URL? = URL(fileURLWithPath: coreBundle)) -> SSHClientInfo {
        .init(name: "Herdr Core", bundleIdentifier: bundleID, bundleURL: bundleURL, command: "ssh git@github.com",
              triggerCommand: "git fetch", showCommand: true, batchMode: false)
    }
    private func snapshot(_ nodes: [RequesterProcessSnapshot.ProcessNode], hints: [HerdrCoreRoutingHint],
                          herdrHints: [HerdrRoutingHint] = []) -> RequesterProcessSnapshot {
        .init(requester: nodes[0], ancestors: Array(nodes.dropFirst()), routingHints: herdrHints, coreRoutingHints: hints)
    }
    private var agentChain: [RequesterProcessSnapshot.ProcessNode] {
        [node(10, "/usr/bin/ssh"), node(11, "/usr/bin/git"), node(12, "/bin/zsh"), node(13, "/opt/claude"),
         node(14, "/bin/zsh"), node(15, holderPath, parent: 16), node(16, holderPath, parent: 1)]
    }

    @Test func agentUnderShellIsProgram() throws {
        let match = try #require(HerdrCoreTerminalResolver.match(clientInfo: client(), snapshot: snapshot(agentChain, hints: [hint(13)])))
        #expect(match.holder.pid == 15)
        #expect(match.terminalRoot.pid == 14)
        #expect(match.programNode?.pid == 13)
        #expect(match.requesterSideNodes.map(\.pid) == [10, 11, 12, 13, 14])
        #expect(match.hint == hint(13))
    }

    @Test func nonShellRootIsProgram() throws {
        let chain = [node(10, "/usr/bin/ssh"), node(11, "/opt/claude"), node(12, holderPath, parent: 1)]
        let match = try #require(HerdrCoreTerminalResolver.match(clientInfo: client(), snapshot: snapshot(chain, hints: [hint(10)])))
        #expect(match.programNode?.pid == 11)
    }

    @Test func requesterIsNeverProgram() throws {
        let chain = [node(10, "/opt/qa-run"), node(11, "/bin/zsh"), node(12, holderPath, parent: 1)]
        let match = try #require(HerdrCoreTerminalResolver.match(clientInfo: client(), snapshot: snapshot(chain, hints: [hint(10)])))
        #expect(match.programNode == nil)
        #expect(match.terminalRoot.pid == 11)
    }

    @Test func loginShellDashIsShell() throws {
        let chain = [node(10, "/usr/bin/ssh"), node(11, "/bin/-zsh"), node(12, holderPath, parent: 1)]
        let match = try #require(HerdrCoreTerminalResolver.match(clientInfo: client(), snapshot: snapshot(chain, hints: [hint(10)])))
        #expect(match.programNode == nil)
    }

    @Test(arguments: ["bundleID", "bundleURL", "noHolder", "rootParent", "noHint", "hintStart", "hintAbove", "conflict"])
    func rejects(_ scenario: String) {
        var info = client()
        var chain = agentChain
        var hints = [hint(13)]
        switch scenario {
        case "bundleID": info = client(bundleID: "com.apple.Terminal")
        case "bundleURL": info = client(bundleURL: nil)
        case "noHolder": chain = [node(10, "/usr/bin/ssh"), node(11, "/bin/zsh", parent: 1)]; hints = [hint(10)]
        case "rootParent": chain[4] = node(14, "/bin/zsh", parent: 99)
        case "noHint": hints = []
        case "hintStart": hints = [hint(13, start: 999)]
        case "hintAbove": hints = [hint(15)]
        case "conflict": hints = [hint(13), hint(12, terminal: "t6")]
        default: Issue.record("Unknown scenario")
        }
        #expect(HerdrCoreTerminalResolver.match(clientInfo: info, snapshot: snapshot(chain, hints: hints)) == nil)
    }

    @Test func classicHerdrHintIgnored() {
        let herdr = HerdrRoutingHint(socketPath: "/tmp/herdr.sock", paneID: "p1", originatingPID: 13, originatingStartTimeMicroseconds: 13)
        #expect(HerdrCoreTerminalResolver.match(clientInfo: client(), snapshot: snapshot(agentChain, hints: [], herdrHints: [herdr])) == nil)
    }

    @Test func missingSnapshotIsNil() {
        #expect(HerdrCoreTerminalResolver.match(clientInfo: client(), snapshot: nil) == nil)
    }
}
