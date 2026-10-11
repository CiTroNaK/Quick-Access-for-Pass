import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite struct RequesterPresentationResolverTests {
    private func node(_ pid: Int32, _ path: String, canonical: String? = nil) -> RequesterProcessSnapshot.ProcessNode {
        .init(pid: pid, parentPID: pid + 1, startTimeMicroseconds: UInt64(pid), executablePath: path, canonicalExecutablePath: canonical ?? path)
    }
    private func entry(_ path: String, enabled: Bool = true, canonical: String? = nil) -> TerminalHostMatchingEntry {
        .init(configuration: .init(id: path, executablePath: path, displayName: "Host", isEnabled: enabled, provider: path.hasSuffix("herdr") ? .herdr : .generic, showPaneDetails: true, isAutomaticallyDetected: false), canonicalExecutablePath: canonical ?? path)
    }
    private var client: SSHClientInfo {
        .init(name: "ssh", bundleIdentifier: nil, bundleURL: nil, command: "ssh git@github.com", triggerCommand: "git fetch --all", showCommand: true, batchMode: false)
    }
    @Test(arguments: ["/bin/herdr", "/custom/terminal"])
    func detachedMappingPreservesIdentity(path: String) {
        let snapshot = RequesterProcessSnapshot(requester: node(10, "/usr/bin/ssh"), ancestors: [node(11, path)], routingHints: [])
        let result = RequesterPresentationResolver.resolve(clientInfo: client, snapshot: snapshot, entries: [entry(path)])
        #expect(result.presentation.name == "Host")
        #expect(result.presentation.symbolName == "terminal")
        #expect(result.hostMatch?.host.pid == 11)
        let connection = VerifiedConnection(fd: -1, identity: .unverified(pid: 10), pid: 10)
        let identity = SSHAuthorizationIdentity(connection: connection, clientInfo: client)
        #expect(identity.requesterAppID == "ssh")
        #expect(identity.persistentCacheID == "ssh:github.com:git fetch --all")
        #expect(client.showCommand)
    }
    @Test func fallbackAndAppPrecedence() {
        let snapshot = RequesterProcessSnapshot(requester: node(10, "/bin/herdr-helper"), ancestors: [], routingHints: [])
        for (snap, entries) in [(snapshot as RequesterProcessSnapshot?, [entry("/bin/herdr")]), (snapshot, [entry("/bin/herdr-helper", enabled: false)]), (nil, [entry("/bin/herdr")])] {
            let result = RequesterPresentationResolver.resolve(clientInfo: client, snapshot: snap, entries: entries)
            #expect(result.presentation.name == "ssh")
            #expect(result.presentation.symbolName == "questionmark.app")
            #expect(result.hostMatch == nil)
        }
        var app = client
        app = .init(name: "Terminal", bundleIdentifier: "com.apple.Terminal", bundleURL: URL(fileURLWithPath: "/Applications/Terminal.app"), command: app.command, triggerCommand: app.triggerCommand, showCommand: true, batchMode: false)
        #expect(RequesterPresentationResolver.resolve(clientInfo: app, snapshot: snapshot, entries: [entry("/bin/herdr-helper")]).presentation.name == "Terminal")
    }
    @Test func nearestCanonicalHostAndBoundary() {
        let hint = HerdrRoutingHint(socketPath: "/tmp/synthetic.sock", paneID: "pane", originatingPID: 10, originatingStartTimeMicroseconds: 10)
        let outer = HerdrRoutingHint(socketPath: "/tmp/outer.sock", paneID: "outer", originatingPID: 12, originatingStartTimeMicroseconds: 12)
        let snapshot = RequesterProcessSnapshot(requester: node(10, "/bin/ssh"), ancestors: [node(11, "/link/herdr", canonical: "/real/herdr"), node(12, "/outer/herdr")], routingHints: [hint, outer])
        let result = RequesterPresentationResolver.resolve(clientInfo: client, snapshot: snapshot, entries: [entry("/outer/herdr"), entry("/link/herdr", canonical: "/real/herdr")])
        #expect(result.hostMatch?.host.pid == 11)
        #expect(result.hostMatch?.requesterSideNodes.map(\.pid) == [10])
        #expect(result.hostMatch?.routingHint == hint)
    }
    @Test func conflictingHintsAreDiscarded() {
        let snapshot = RequesterProcessSnapshot(requester: node(10, "/bin/ssh"), ancestors: [node(11, "/bin/sh"), node(12, "/bin/herdr")], routingHints: [
            .init(socketPath: "/tmp/a.sock", paneID: "a", originatingPID: 10, originatingStartTimeMicroseconds: 10),
            .init(socketPath: "/tmp/b.sock", paneID: "b", originatingPID: 11, originatingStartTimeMicroseconds: 11)])
        #expect(RequesterPresentationResolver.resolve(clientInfo: client, snapshot: snapshot, entries: [entry("/bin/herdr")]).hostMatch?.routingHint == nil)
    }
}
